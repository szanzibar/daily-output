defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping ReqLLM. Every call goes through `chat/1`, which picks the model, sets
  its reasoning effort, records usage for cost tracking, and logs one line per call.

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

  @doc "Whether the API key for `provider` (:anthropic | :openai | :openrouter) is configured."
  def api_key_set?(provider), do: match?({:ok, _}, get_api_key(provider))

  @doc "The env var that holds `provider`'s API key."
  def api_key_var(provider), do: Map.fetch!(@key_vars, provider)

  @doc "The env var the model picked in Settings reads its API key from."
  def key_var(config), do: api_key_var(selected_provider(config))

  @doc "`key_var/1` when that key isn't set, so every AI call fails. Nil when it is."
  def missing_key_var(config \\ Settings.get_config()) do
    provider = selected_provider(config)
    if !api_key_set?(provider), do: api_key_var(provider)
  end

  @doc "Warns at boot when the model picked in Settings has no API key."
  def warn_if_key_missing do
    if var = missing_key_var() do
      Logger.warning(
        "AI: #{var} is not set, so AI features won't work until you set it and restart."
      )
    end
  end

  defp selected_provider(config) do
    {provider, _model_id} = parse_spec(spec_for(config.ai_provider, config.ai_model))
    provider
  end

  defp get_api_key(provider) do
    case Application.get_env(:daily_output, :"#{provider}_api_key") ||
           System.get_env(@key_vars[provider]) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :api_key_not_set}
    end
  end

  @doc """
  Sends one request. `:purpose` tags it for cost tracking, `:model` (a "provider:id" spec)
  overrides the Settings choice, and `:effort` overrides the model's reasoning effort.

  With `:schema` (a JSON schema) it returns `{:ok, map}`, or `{:error, :unparsed}` when the
  reply has no decodable object. Without it, it returns `{:ok, text}`.
  """
  def chat(opts) do
    {purpose, opts} = Keyword.pop!(opts, :purpose)
    {provider, model_id} = resolve_model(opts)
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, api_key} <- get_api_key(provider),
           {:ok, response} <- req_llm_chat(provider, api_key, model_id, opts) do
        Logger.info(
          "AI #{purpose} #{model_id}: #{System.monotonic_time(:millisecond) - started} ms, " <>
            "#{response.usage[:input_tokens]} in / #{response.usage[:output_tokens]} out tokens"
        )

        record_usage(purpose, response)
        if opts[:schema], do: structured(response), else: {:ok, ReqLLM.Response.text(response)}
      end

    with {:error, reason} <- result do
      Logger.error("AI #{purpose} #{model_id} failed: #{describe(reason, provider)}")
    end

    result
  end

  # ReqLLM errors also hold the request and response bodies, so log only their message.
  defp describe(:api_key_not_set, provider), do: "#{api_key_var(provider)} is not set"
  defp describe(reason, _provider) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason, _provider), do: inspect(reason)

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

  # A per-call `:model` spec (the bench) beats the Settings choice.
  defp resolve_model(opts) do
    parse_spec(
      opts[:model] || then(Settings.get_config(), &spec_for(&1.ai_provider, &1.ai_model))
    )
  end

  defp parse_spec(spec) do
    [provider, model_id] = String.split(spec, ":", parts: 2)
    {Map.fetch!(@providers, provider), model_id}
  end

  @doc "The reasoning effort `model_id` runs at, from either route."
  def effort(model_id), do: Map.fetch!(@effort, String.replace_prefix(model_id, "openai/", ""))

  @doc "Maps a Settings `{ai_provider, ai_model}` pair to a ReqLLM \"provider:model\" spec."
  def spec_for("direct", "gpt-6.1-sol"), do: "openai:gpt-6.1-sol"
  def spec_for("direct", "gpt-6-luna"), do: "openai:gpt-6-luna"
  def spec_for("openrouter", "gpt-6.1-sol"), do: "openrouter:openai/gpt-6.1-sol"
  def spec_for("openrouter", "gpt-6-luna"), do: "openrouter:openai/gpt-6-luna"

  defp req_llm_chat(provider, api_key, model_id, opts) do
    # A struct, not a catalog string, so OpenAI Sol keeps the strict tool instead of
    # json_schema, and OpenRouter Sol resolves even though the catalog doesn't list it.
    {:ok, model} = ReqLLM.model(%{provider: provider, id: model_id})
    context = build_context(opts[:system], opts[:messages] || [])
    effort = opts[:effort] || effort(model_id)

    # Sonnet 5.5 thinks unless told "between_tools", and ReqLLM sends nothing for :none.
    effort_opts =
      if provider == :anthropic and effort == :none,
        do: [thinking: %{type: "between_tools"}],
        else: [reasoning_effort: effort]

    req_opts =
      [
        api_key: api_key,
        max_tokens: Keyword.fetch!(opts, :max_tokens),
        receive_timeout: @receive_timeout,
        req_http_options: @http_options,
        # Otherwise every OpenAI call logs that ReqLLM renamed :max_tokens.
        on_unsupported: :ignore
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

  # Cost tracking must never break the chat flow — swallow and log any failure.
  defp record_usage(purpose, response) do
    Stats.record_usage(purpose, response.model, response.usage)
  rescue
    error ->
      Logger.warning("Failed to record API usage: #{inspect(error)}")
      {:error, :usage_not_recorded}
  end
end
