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

  alias DailyOutput.Cache

  @model_cache_key "anthropic_sonnet_model"

  defdelegate generate_prompts(topics, target_language, native_language),
    to: PromptGenerator

  defdelegate generate_openers(topics, target_language, native_language),
    to: TopicGenerator

  defdelegate proofread(text, opts), to: Proofreader

  defdelegate conversation_respond(messages, opts), to: ConversationPartner, as: :respond

  defdelegate summarize_focus_topic(tip_text), to: FocusSummarizer, as: :summarize

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

  def chat(client, opts) do
    requested_model = Keyword.get(opts, :model)
    model_result = if is_binary(requested_model), do: {:ok, requested_model}, else: model()

    with {:ok, model_id} <- model_result do
      request_opts = Keyword.put(opts, :model, model_id)

      case Anthropix.chat(client, request_opts) do
        {:error, %Anthropix.APIError{} = api_error} = error ->
          if model_not_found_error?(api_error) do
            retry_chat_with_refreshed_model(client, opts, model_id, error)
          else
            error
          end

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

  defp retry_chat_with_refreshed_model(client, opts, failed_model, original_error) do
    case model(true) do
      {:ok, refreshed_model} ->
        if refreshed_model == failed_model do
          original_error
        else
          Logger.warning(
            "AI model '#{failed_model}' not found. Retrying with '#{refreshed_model}'."
          )

          Anthropix.chat(client, Keyword.put(opts, :model, refreshed_model))
        end

      {:error, reason} ->
        {:error, reason}
    end
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
