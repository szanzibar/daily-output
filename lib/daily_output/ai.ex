defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping ReqLLM. Every call goes through `chat/2`, which picks the model, sets
  thinking, and records usage for cost tracking.

  There are two models, Claude Sonnet 5.5 (default) and GPT-5.6 Luna, each reached directly
  or through OpenRouter (see `spec_for/2`). Thinking is off unless a call passes
  `thinking: true`.

  Structured calls pass a JSON `schema:` and use the provider's structured outputs, not a
  forced tool, because Sonnet 5.5 rejects a forced `tool_choice`.
  """

  require Logger

  alias DailyOutput.{Settings, Stats}

  @key_vars %{
    anthropic: "ANTHROPIC_API_KEY",
    openai: "OPENAI_API_KEY",
    openrouter: "OPENROUTER_API_KEY"
  }

  # AI is "ready" if any provider key is configured; chat/2 resolves the key per call.
  def client do
    if Enum.any?(Map.keys(@key_vars), &api_key_set?/1),
      do: {:ok, :ready},
      else: {:error, :api_key_not_set}
  end

  @doc "Whether the API key for `provider` (:anthropic | :openai | :openrouter) is configured."
  def api_key_set?(provider), do: match?({:ok, _}, get_api_key(provider))

  @doc "The env var that holds `provider`'s API key."
  def api_key_var(provider), do: Map.fetch!(@key_vars, provider)

  defp get_api_key(provider) do
    case Application.get_env(:daily_output, :"#{provider}_api_key") ||
           System.get_env(@key_vars[provider]) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :api_key_not_set}
    end
  end

  @doc """
  Concatenates the text from a response's content blocks, skipping non-text blocks.
  Returns "" when there is no text block.
  """
  def text_content(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  @doc """
  Sends one request. `:purpose` tags it for cost tracking, `:model` (a "provider:id" spec)
  overrides the Settings choice, and `thinking: true` turns reasoning on.

  With `:schema` (a JSON schema) it returns `{:ok, map}`, or `{:error, :unparsed}` when the
  reply has no decodable object. Without it, it returns the response for `text_content/1`.
  """
  def chat(_client, opts) do
    {purpose, opts} = Keyword.pop(opts, :purpose)
    {provider, model_id} = resolve_model(opts)

    with {:ok, api_key} <- get_api_key(provider),
         {:ok, response} <- req_llm_chat(provider, api_key, model_id, opts) do
      shaped = anthropic_shape(response, model_id)
      record_usage(purpose, shaped)
      if opts[:schema], do: structured(response), else: {:ok, shaped}
    end
  end

  @doc false
  def structured(%ReqLLM.Response{} = response) do
    case ReqLLM.Response.object(response) do
      %{} = object ->
        {:ok, object}

      _ ->
        Logger.warning("AI: no structured output in #{inspect(ReqLLM.Response.text(response))}")
        {:error, :unparsed}
    end
  end

  @providers %{"anthropic" => :anthropic, "openai" => :openai, "openrouter" => :openrouter}

  # A per-call `:model` spec (the bench) beats the Settings choice. The config default only
  # applies when Settings can't be read.
  defp resolve_model(opts) do
    spec = opts[:model] || settings_spec() || Application.fetch_env!(:daily_output, :ai_model)
    [provider, model_id] = String.split(spec, ":", parts: 2)
    {Map.fetch!(@providers, provider), model_id}
  end

  # nil when there's no DB (some unit tests), so resolution falls back to config.
  defp settings_spec do
    config = Settings.get_config()
    spec_for(config.ai_provider, config.ai_model)
  rescue
    _ -> nil
  end

  @doc "Maps a Settings `{ai_provider, ai_model}` pair to a ReqLLM \"provider:model\" spec."
  def spec_for("openrouter", "gpt-5.6-luna"), do: "openrouter:openai/gpt-5.6-luna"
  def spec_for("openrouter", "sonnet-5.5"), do: "openrouter:anthropic/claude-sonnet-5.5"
  def spec_for("direct", "gpt-5.6-luna"), do: "openai:gpt-5.6-luna"
  def spec_for("direct", "sonnet-5.5"), do: "anthropic:claude-sonnet-5-5"

  defp req_llm_chat(provider, api_key, model_id, opts) do
    # A struct, not a string, so ReqLLM doesn't warn about ids newer than its catalog.
    {:ok, model} = ReqLLM.model(%{provider: provider, id: model_id})
    context = build_context(opts[:system], opts[:messages] || [])

    req_opts =
      put_thinking(
        [api_key: api_key, max_tokens: Keyword.fetch!(opts, :max_tokens)],
        provider,
        opts[:thinking] || false
      )

    case opts[:schema] do
      nil ->
        ReqLLM.generate_text(model, context, req_opts)

      schema ->
        ReqLLM.generate_object(model, context, schema, put_structured_mode(req_opts, provider))
    end
  end

  # OpenRouter's default structured mode is a forced tool, which Sonnet 5.5 rejects.
  defp put_structured_mode(opts, :openrouter),
    do: Keyword.put(opts, :provider_options, openrouter_structured_output_mode: :json_schema)

  defp put_structured_mode(opts, _provider), do: opts

  # Sonnet 5.5 turns thinking off with "between_tools" and rejects "disabled". OpenAI-style
  # APIs take reasoning_effort :none. "On" means the model's own default.
  defp put_thinking(opts, :anthropic, false),
    do: Keyword.put(opts, :thinking, %{type: "between_tools"})

  defp put_thinking(opts, :anthropic, true), do: Keyword.put(opts, :thinking, %{type: "adaptive"})
  defp put_thinking(opts, _provider, false), do: Keyword.put(opts, :reasoning_effort, :none)
  defp put_thinking(opts, _provider, true), do: opts

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

  # Reshape a %ReqLLM.Response{} into the Anthropic-native map that text_content/1 and
  # Stats.record_usage/2 read.
  @doc false
  def anthropic_shape(%ReqLLM.Response{} = response, fallback_model) do
    text = ReqLLM.Response.text(response)
    usage = response.usage || %{}

    %{
      "content" =>
        if(is_binary(text) and text != "", do: [%{"type" => "text", "text" => text}], else: []),
      "model" => response.model || fallback_model,
      "usage" => %{
        "input_tokens" => usage_field(usage, :input_tokens),
        "output_tokens" => usage_field(usage, :output_tokens),
        # Always 0 on Anthropic: ReqLLM 1.17 reads the wrong field. Known and accepted.
        "reasoning_tokens" => usage_field(usage, :reasoning_tokens),
        # ReqLLM normalizes Anthropic's cache_read/cache_creation to these names.
        "cache_read_input_tokens" => usage_field(usage, :cached_tokens),
        "cache_creation_input_tokens" => usage_field(usage, :cache_creation_tokens),
        # nil when ReqLLM's catalog has no price for the model.
        "total_cost" => usage[:total_cost] || usage["total_cost"]
      }
    }
  end

  defp usage_field(usage, key), do: usage[key] || usage[to_string(key)] || 0

  # Cost tracking must never break the chat flow — swallow and log any failure.
  defp record_usage(purpose, response) do
    Stats.record_usage(purpose, response)
  rescue
    error ->
      Logger.warning("Failed to record API usage: #{inspect(error)}")
      {:error, :usage_not_recorded}
  end
end
