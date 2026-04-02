defmodule DailyOutput.AI do
  @moduledoc """
  AI context wrapping Anthropix for prompt generation and proofreading.
  """

  alias DailyOutput.AI.{PromptGenerator, Proofreader, TopicGenerator, ConversationPartner, FocusSummarizer}
  alias DailyOutput.Cache

  @model_cache_key "anthropic_sonnet_model"
  @fallback_model "claude-sonnet-4-5-20241022"

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

  def model do
    case Cache.get(@model_cache_key, 86400) do
      nil -> discover_model()
      cached -> cached
    end
  end

  defp discover_model do
    case fetch_models() do
      {:ok, model_id} ->
        Cache.put(@model_cache_key, model_id)
        model_id

      {:error, _reason} ->
        @fallback_model
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
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :api_key_not_set}
      "" -> {:error, :api_key_not_set}
      key -> {:ok, key}
    end
  end

  defp pick_latest_sonnet(models) do
    sonnet =
      models
      |> Enum.filter(fn m -> String.contains?(m["id"], "sonnet") end)
      |> Enum.sort_by(fn m -> m["created_at"] || m["id"] end, :desc)
      |> List.first()

    case sonnet do
      nil -> {:error, :no_sonnet_found}
      %{"id" => id} -> {:ok, id}
    end
  end
end
