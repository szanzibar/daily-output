defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping ReqLLM. Every call goes through `chat/2`, which picks the model, sets
  its reasoning effort, and records usage for cost tracking.

  Settings offers two models, GPT-6.1 Sol (default) and GPT-6 Luna, each reached directly or
  through OpenRouter (see `spec_for/2`). Anthropic stays wired up for the bench and the next
  model switch. Effort belongs to the model; only the bench overrides it.

  Structured calls pass a JSON `schema:`. OpenAI uses a strict forced tool; OpenRouter and
  Anthropic use json_schema, because Sonnet 5.5 rejects a forced `tool_choice`.
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
  overrides the Settings choice, and `:effort` overrides the model's reasoning effort.

  With `:schema` (a JSON schema) it returns `{:ok, map}`, or `{:error, :unparsed}` when the
  reply has no decodable object. Without it, it returns the response for `text_content/1`.
  """
  def chat(_client, opts) do
    {purpose, opts} = Keyword.pop(opts, :purpose)
    {provider, model_id} = resolve_model(opts)

    with {:ok, api_key} <- get_api_key(provider),
         {:ok, response} <- req_llm_chat(provider, api_key, model_id, opts) do
      shaped = normalize_response(response, model_id)
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

  # Sol rejects :none. Luna at :low reasons 0 tokens on structured calls; :medium matches Sol
  # on corrections. Sonnet 5.5 measured best with thinking off.
  @effort %{"gpt-6.1-sol" => :low, "gpt-6-luna" => :medium, "claude-sonnet-5-5" => :none}

  # ReqLLM waits up to 300 s on Responses API calls; the slowest real call takes ~14 s. It
  # retries a timeout up to 3 times, so a stall now costs a minute per try, not five.
  @receive_timeout 60_000

  # Tests answer through `Req.Test` stubs, so they never reach the network.
  @http_options if(Mix.env() == :test, do: [plug: {Req.Test, __MODULE__}], else: [])

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

  @doc "The reasoning effort `model_id` runs at, from either route."
  def effort(model_id), do: Map.fetch!(@effort, String.replace_prefix(model_id, "openai/", ""))

  @doc "Maps a Settings `{ai_provider, ai_model}` pair to a ReqLLM \"provider:model\" spec."
  def spec_for("direct", "gpt-6.1-sol"), do: "openai:gpt-6.1-sol"
  def spec_for("direct", "gpt-6-luna"), do: "openai:gpt-6-luna"
  def spec_for("openrouter", "gpt-6.1-sol"), do: "openrouter:openai/gpt-6.1-sol"
  def spec_for("openrouter", "gpt-6-luna"), do: "openrouter:openai/gpt-6-luna"

  defp req_llm_chat(provider, api_key, model_id, opts) do
    # A struct, not a string, so ReqLLM doesn't warn about ids newer than its catalog. It
    # only knows gpt-5* use the Responses API; newer ids would hit Chat Completions and 400.
    extra = if provider == :openai, do: %{wire: %{protocol: "openai_responses"}}, else: %{}
    {:ok, model} = ReqLLM.model(%{provider: provider, id: model_id, extra: extra})
    context = build_context(opts[:system], opts[:messages] || [])
    effort = opts[:effort] || effort(model_id)

    # Sonnet 5.5 thinks unless told "between_tools" and rejects "disabled". ReqLLM would send
    # it a budget_tokens thinking config, which it also rejects.
    effort_opts =
      cond do
        provider != :anthropic -> [reasoning_effort: effort]
        effort == :none -> [thinking: %{type: "between_tools"}]
        true -> [thinking: %{type: "adaptive"}, output_config: %{effort: to_string(effort)}]
      end

    req_opts =
      [
        api_key: api_key,
        max_tokens: Keyword.fetch!(opts, :max_tokens),
        receive_timeout: @receive_timeout,
        req_http_options: @http_options
      ] ++ effort_opts

    case opts[:schema] do
      nil ->
        ReqLLM.generate_text(model, context, req_opts)

      schema ->
        # OpenRouter's forced tool isn't strict, so it gets json_schema. OpenAI keeps ReqLLM's
        # strict tool, because json_schema made Luna reason twice as long on the same calls.
        # ReqLLM already picks json_schema for Anthropic.
        req_opts =
          if provider == :openrouter,
            do: [{:provider_options, openrouter_structured_output_mode: :json_schema} | req_opts],
            else: req_opts

        ReqLLM.generate_object(model, context, schema, req_opts)
    end
  end

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

  # Reshape a %ReqLLM.Response{} into the plain map that text_content/1 and
  # Stats.record_usage/2 read.
  @doc false
  def normalize_response(%ReqLLM.Response{} = response, fallback_model) do
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
        # Part of input_tokens on OpenAI, counted apart on Anthropic.
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
