defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping Anthropix for prompt generation and proofreading.
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

  def client do
    case Application.get_env(:daily_output, :anthropic_api_key) do
      nil -> {:error, :api_key_not_set}
      "" -> {:error, :api_key_not_set}
      api_key -> {:ok, Anthropix.init(api_key)}
    end
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

  def chat(client, opts) do
    # `:purpose` tags the call site for cost tracking; it's ours, not Anthropix's,
    # so strip it before the request goes out.
    {purpose, opts} = Keyword.pop(opts, :purpose)
    requested_model = Keyword.get(opts, :model)
    model_result = if is_binary(requested_model), do: {:ok, requested_model}, else: model()

    with {:ok, model_id} <- model_result do
      request_opts = Keyword.put(opts, :model, model_id)

      case Anthropix.chat(client, request_opts) do
        {:error, %Anthropix.APIError{} = api_error} = error ->
          if model_not_found_error?(api_error) do
            retry_chat_with_refreshed_model(client, opts, model_id, purpose, error)
          else
            error
          end

        {:ok, response} = ok ->
          record_usage(purpose, response)
          ok

        other ->
          other
      end
    end
  end

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
    with {:ok, api_key} <- get_api_key() do
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

  defp get_api_key do
    case Application.get_env(:daily_output, :anthropic_api_key) ||
           System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :api_key_not_set}
      "" -> {:error, :api_key_not_set}
      key -> {:ok, key}
    end
  end

  defp model_not_found_error?(%Anthropix.APIError{status: 404, type: "not_found_error"} = err) do
    message = Map.get(err, :message, "")
    String.contains?(message, "model")
  end

  defp model_not_found_error?(_), do: false

  defp retry_chat_with_refreshed_model(client, opts, failed_model, purpose, original_error) do
    case model(true) do
      {:ok, refreshed_model} ->
        if refreshed_model == failed_model do
          original_error
        else
          Logger.warning(
            "AI model '#{failed_model}' not found. Retrying with '#{refreshed_model}'."
          )

          case Anthropix.chat(client, Keyword.put(opts, :model, refreshed_model)) do
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
