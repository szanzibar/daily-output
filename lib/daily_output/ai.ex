defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping ReqLLM for prompt generation and proofreading.

  All calls go through `chat/2`, which sends `thinking: %{type: "disabled"}` so the
  model does not burn output tokens on reasoning (see `thinking_opt/0`). The ReqLLM
  response is reshaped back into the Anthropic-native `%{"content" => ..., "usage" =>
  ..., "model" => ...}` map so callers, `text_content/1`, `tool_use/1`, and
  `DailyOutput.Stats.record_usage/2` are unchanged from the Anthropix era.
  """

  require Logger

  alias DailyOutput.AI.{
    PromptGenerator,
    Proofreader,
    TopicGenerator,
    ConversationPartner,
    FocusSummarizer
  }

  alias DailyOutput.{Cache, PromptCache, Stats}

  @model_cache_key "anthropic_sonnet_model"

  defdelegate generate_prompts(topics, target_language, native_language),
    to: PromptGenerator

  defdelegate generate_openers(topics, target_language, native_language),
    to: TopicGenerator

  defdelegate proofread(text, opts), to: Proofreader

  defdelegate proofread_message(text, opts), to: Proofreader

  defdelegate assess_conversation(messages, opts), to: Proofreader

  defdelegate conversation_respond(messages, opts), to: ConversationPartner, as: :respond

  defdelegate conversation_open(topic, opts), to: ConversationPartner, as: :open

  defdelegate summarize_focus_topic(tip_text), to: FocusSummarizer, as: :summarize

  @doc "Returns today's cached journal prompts, or `nil` if none have been generated yet."
  def cached_prompts(topics, target_language, native_language),
    do: PromptCache.get(:prompts, topics, target_language, native_language)

  @doc "Generates a fresh set of journal prompts and caches them for the day."
  def refresh_prompts(topics, target_language, native_language) do
    with {:ok, prompts} <- generate_prompts(topics, target_language, native_language) do
      {:ok, PromptCache.put(:prompts, topics, target_language, native_language, prompts)}
    end
  end

  @doc "Returns today's cached conversation openers, or `nil` if none have been generated yet."
  def cached_openers(topics, target_language, native_language),
    do: PromptCache.get(:openers, topics, target_language, native_language)

  @doc "Generates a fresh set of conversation openers and caches them for the day."
  def refresh_openers(topics, target_language, native_language) do
    with {:ok, openers} <- generate_openers(topics, target_language, native_language) do
      {:ok, PromptCache.put(:openers, topics, target_language, native_language, openers)}
    end
  end

  # AI is "ready" if any provider key is configured; chat/2 resolves the specific
  # provider + key per call (it can vary by purpose — see resolve_model/2). The {:ok, _}
  # contract is kept so call sites don't change.
  def client do
    if match?({:ok, _}, get_api_key(:anthropic)) or match?({:ok, _}, get_api_key(:zai)),
      do: {:ok, :ready},
      else: {:error, :api_key_not_set}
  end

  def model(force_refresh \\ false) do
    if force_refresh do
      discover_model()
    else
      case Cache.get(@model_cache_key, 86400) do
        nil -> discover_model()
        cached -> {:ok, cached}
      end
    end
  end

  @doc """
  Concatenates the text from an Anthropic response's content blocks, skipping
  non-text blocks. Thinking-enabled models (sonnet-5 thinks by default) emit a
  `thinking` block before the `text` block, so callers must not assume `content`
  starts with text. Returns "" when there is no text block.
  """
  def text_content(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  @doc """
  Returns the `input` map of the first `tool_use` block in a response, or `nil`
  when there is none. Like `text_content/1`, this keeps the Anthropic response
  shape out of callers.
  """
  def tool_use(%{"content" => blocks}) when is_list(blocks) do
    case Enum.find(blocks, &(&1["type"] == "tool_use")) do
      %{"input" => input} -> input
      _ -> nil
    end
  end

  def chat(_client, opts) do
    # `:purpose` tags the call site for cost tracking; it's ours, not the API's, so strip
    # it before the request goes out. It also selects the model/provider for low-stakes
    # paths (see resolve_model/2), so the matching key is resolved per call.
    {purpose, opts} = Keyword.pop(opts, :purpose)

    with {:ok, provider, model_id} <- resolve_model(purpose, opts),
         {:ok, api_key} <- get_api_key(provider) do
      case req_llm_chat(provider, api_key, model_id, opts) do
        {:ok, response} = ok ->
          record_usage(purpose, response)
          ok

        {:error, error_struct} = error ->
          # Only the Anthropic path auto-discovers, so only it can recover a stale id.
          if provider == :anthropic and model_not_found_error?(error_struct) do
            retry_chat_with_refreshed_model(api_key, opts, model_id, purpose, error)
          else
            error
          end
      end
    end
  end

  # Resolve this call's model as {provider, model_id}. Precedence:
  #   1. a per-call `:model` spec (rare),
  #   2. a per-purpose override (`:ai_model_overrides` routes low-stakes paths like
  #      flashcards/prompts/openers to a cheaper model; correction paths have no override),
  #   3. the global `:ai_model` spec,
  #   4. otherwise discover the latest Anthropic Sonnet (the historical default).
  # A spec is "provider:model", e.g. "zai:glm-5.2" or "anthropic:claude-sonnet-4-6".
  defp resolve_model(purpose, opts) do
    spec =
      Keyword.get(opts, :model) ||
        purpose_override(purpose) ||
        Application.get_env(:daily_output, :ai_model)

    case spec do
      spec when is_binary(spec) ->
        case parse_spec(spec) do
          {provider, model_id} -> {:ok, provider, model_id}
          :error -> {:error, {:bad_model_spec, spec}}
        end

      _ ->
        with {:ok, model_id} <- model(), do: {:ok, :anthropic, model_id}
    end
  end

  defp purpose_override(nil), do: nil

  defp purpose_override(purpose) do
    :daily_output
    |> Application.get_env(:ai_model_overrides, %{})
    |> Map.get(to_string(purpose))
  end

  @providers %{"anthropic" => :anthropic, "zai" => :zai}
  defp parse_spec(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, id] when id != "" ->
        case Map.fetch(@providers, provider) do
          {:ok, atom} -> {atom, id}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  # Translate our Anthropic-style opts into a ReqLLM call and reshape the result back.
  defp req_llm_chat(provider, api_key, model_id, opts) do
    context = build_context(Keyword.get(opts, :system), Keyword.get(opts, :messages, []))

    req_opts =
      [api_key: api_key]
      |> put_opt(:max_tokens, Keyword.get(opts, :max_tokens))
      |> put_opt(:tools, to_req_tools(Keyword.get(opts, :tools)))
      |> put_opt(:tool_choice, Keyword.get(opts, :tool_choice))
      |> put_thinking(provider)

    case ReqLLM.generate_text(model_spec(provider, model_id), context, req_opts) do
      {:ok, response} -> {:ok, anthropic_shape(response, model_id)}
      error -> error
    end
  end

  # Resolve to a model struct so ReqLLM doesn't re-resolve the "provider:<id>" string and
  # log an "unverified model" warning on every call — our models are routinely newer than
  # ReqLLM's static catalog. Falls back to the string spec if the provider can't build one.
  defp model_spec(provider, model_id) do
    case ReqLLM.model(%{provider: provider, id: model_id}) do
      {:ok, model} -> model
      _ -> "#{provider}:#{model_id}"
    end
  end

  # ReqLLM's Anthropic encoder only accepts %ReqLLM.Tool{} structs
  # (Schema.to_openai_format/1 has no clause for a raw map), so wrap our Anthropic-native
  # tool maps. A JSON-schema map in :parameter_schema passes through to the request's
  # input_schema untouched (Schema.to_json/1), producing the same tool the proofreader
  # intended. The required :callback is never invoked — generate_text returns the tool
  # call, it does not execute it. `tool_choice` (a %{type: "tool", name: ...} map) is
  # accepted as-is by ReqLLM.
  defp to_req_tools(nil), do: nil

  defp to_req_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      ReqLLM.tool(
        name: tool_field(tool, :name),
        description: tool_field(tool, :description),
        parameter_schema: tool_field(tool, :input_schema),
        callback: fn _args -> {:ok, nil} end
      )
    end)
  end

  defp tool_field(tool, key), do: tool[key] || tool[to_string(key)]

  defp build_context(system, messages) do
    system_msgs =
      if is_binary(system) and system != "", do: [ReqLLM.Context.system(system)], else: []

    turn_msgs =
      Enum.map(messages, fn
        %{role: "assistant", content: content} -> ReqLLM.Context.assistant(content)
        %{role: _role, content: content} -> ReqLLM.Context.user(content)
      end)

    ReqLLM.Context.new(system_msgs ++ turn_msgs)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Disable model reasoning by default so it doesn't spend output tokens thinking — the
  # whole reason for the ReqLLM swap. Placement differs by provider: Anthropic reads a
  # top-level `thinking:`; z.ai reads it under `provider_options`. Set
  # `config :daily_output, :ai_thinking, false` to omit it (fallback for a model that
  # rejects an explicit "disabled"), or to a map to send a specific config — no code change.
  @default_thinking %{type: "disabled"}
  defp put_thinking(opts, provider) do
    case Application.get_env(:daily_output, :ai_thinking, @default_thinking) do
      thinking when is_map(thinking) -> place_thinking(opts, provider, thinking)
      _ -> opts
    end
  end

  defp place_thinking(opts, :zai, thinking) do
    Keyword.update(
      opts,
      :provider_options,
      [thinking: thinking],
      &Keyword.put(&1, :thinking, thinking)
    )
  end

  defp place_thinking(opts, _provider, thinking), do: Keyword.put(opts, :thinking, thinking)

  # Reshape a %ReqLLM.Response{} into the Anthropic-native map the rest of the app reads
  # (text_content/1, tool_use/1, Stats.record_usage/2), so nothing downstream changed.
  @doc false
  def anthropic_shape(%ReqLLM.Response{} = response, fallback_model) do
    text = ReqLLM.Response.text(response)

    text_blocks =
      if is_binary(text) and text != "", do: [%{"type" => "text", "text" => text}], else: []

    tool_blocks =
      response
      |> ReqLLM.Response.tool_calls()
      |> Enum.map(fn tool_call ->
        %{name: name, arguments: arguments} = ReqLLM.ToolCall.to_map(tool_call)
        %{"type" => "tool_use", "name" => name, "input" => arguments}
      end)

    usage = response.usage || %{}

    %{
      "content" => text_blocks ++ tool_blocks,
      "model" => response.model || fallback_model,
      "usage" => %{
        "input_tokens" => usage_field(usage, :input_tokens),
        "output_tokens" => usage_field(usage, :output_tokens),
        # ReqLLM normalizes Anthropic's cache_read/cache_creation to these names.
        "cache_read_input_tokens" => usage_field(usage, :cached_tokens),
        "cache_creation_input_tokens" => usage_field(usage, :cache_creation_tokens)
      }
    }
  end

  defp usage_field(usage, key), do: usage[key] || usage[to_string(key)] || 0

  defp discover_model do
    case fetch_models() do
      {:ok, model_info} ->
        model_id = model_info.id
        Cache.put(@model_cache_key, model_id)

        Logger.info(
          "Selected Anthropic Sonnet model from API: id=#{model_info.id} display_name=#{inspect(model_info.display_name)} created_at=#{inspect(model_info.created_at)}"
        )

        {:ok, model_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_models do
    with {:ok, api_key} <- get_api_key(:anthropic) do
      req =
        Req.new(
          url: "https://api.anthropic.com/v1/models",
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ]
        )

      case Req.get(req) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          pick_latest_sonnet(models)

        {:ok, %{status: status, body: body}} ->
          {:error, "API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_api_key(:zai) do
    fetch_key(System.get_env("ZAI_API_KEY") || Application.get_env(:daily_output, :zai_api_key))
  end

  defp get_api_key(_anthropic) do
    fetch_key(
      Application.get_env(:daily_output, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")
    )
  end

  defp fetch_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp fetch_key(_), do: {:error, :api_key_not_set}

  # A 404 from /v1/messages means the model id is unknown — the trigger to re-discover.
  defp model_not_found_error?(%ReqLLM.Error.API.Response{status: 404}), do: true
  defp model_not_found_error?(_), do: false

  defp retry_chat_with_refreshed_model(api_key, opts, failed_model, purpose, original_error) do
    case model(true) do
      {:ok, refreshed_model} ->
        if refreshed_model == failed_model do
          original_error
        else
          Logger.warning(
            "AI model '#{failed_model}' not found. Retrying with '#{refreshed_model}'."
          )

          case req_llm_chat(:anthropic, api_key, refreshed_model, opts) do
            {:ok, response} = ok ->
              record_usage(purpose, response)
              ok

            other ->
              other
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cost tracking must never break the chat flow — swallow and log any failure.
  defp record_usage(purpose, response) do
    Stats.record_usage(purpose, response)
  rescue
    error ->
      Logger.warning("Failed to record API usage: #{inspect(error)}")
      {:error, :usage_not_recorded}
  end

  defp pick_latest_sonnet(models) do
    sonnet =
      models
      |> Enum.filter(fn m -> String.contains?(m["id"], "sonnet") end)
      |> Enum.sort_by(fn m -> m["created_at"] || m["id"] end, :desc)
      |> List.first()

    case sonnet do
      nil ->
        {:error, :no_sonnet_found}

      %{"id" => id} = model ->
        {:ok,
         %{
           id: id,
           display_name: model["display_name"],
           created_at: model["created_at"]
         }}
    end
  end
end
