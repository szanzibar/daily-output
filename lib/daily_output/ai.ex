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
    FocusSummarizer,
    OpenRouterClient
  }

  alias DailyOutput.Cache
  alias DailyOutput.Settings

  @model_cache_key "anthropic_sonnet_model"

  defdelegate generate_prompts(topics, target_language, native_language),
    to: PromptGenerator

  defdelegate generate_openers(topics, target_language, native_language),
    to: TopicGenerator

  defdelegate proofread(text, opts), to: Proofreader

  defdelegate conversation_respond(messages, opts), to: ConversationPartner, as: :respond

  defdelegate summarize_focus_topic(tip_text), to: FocusSummarizer, as: :summarize

  def client do
    case current_provider() do
      "openrouter" ->
        case openrouter_api_key() do
          {:ok, key} -> {:ok, {:openrouter, key}}
          error -> error
        end

      _ ->
        case Application.get_env(:daily_output, :anthropic_api_key) do
          nil -> {:error, :api_key_not_set}
          "" -> {:error, :api_key_not_set}
          api_key -> {:ok, {:anthropic, Anthropix.init(api_key)}}
        end
    end
  end

  def openrouter_api_key do
    key =
      case Application.get_env(:daily_output, :openrouter_api_key) do
        nil -> System.get_env("OPENROUTER_API_KEY")
        "" -> System.get_env("OPENROUTER_API_KEY")
        key -> key
      end

    case key do
      nil -> {:error, :api_key_not_set}
      "" -> {:error, :api_key_not_set}
      key -> {:ok, key}
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

    model_result =
      cond do
        is_binary(requested_model) -> {:ok, requested_model}
        match?({:openrouter, _}, client) -> openrouter_model()
        true -> model()
      end

    with {:ok, model_id} <- model_result do
      request_opts = Keyword.put(opts, :model, model_id)

      case client do
        {:openrouter, api_key} ->
          OpenRouterClient.chat(api_key, request_opts)

        {:anthropic, anthropix_client} ->
          chat_anthropic(anthropix_client, request_opts, opts, model_id)

        # Legacy: bare Anthropix client (backwards compat)
        anthropix_client ->
          chat_anthropic(anthropix_client, request_opts, opts, model_id)
      end
    end
  end

  defp chat_anthropic(anthropix_client, request_opts, original_opts, model_id) do
    case Anthropix.chat(anthropix_client, request_opts) do
      {:error, %Anthropix.APIError{} = api_error} = error ->
        if model_not_found_error?(api_error) do
          retry_chat_with_refreshed_model(anthropix_client, original_opts, model_id, error)
        else
          error
        end

      other ->
        other
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

  @doc false
  def current_provider do
    config = Settings.get_config()
    config.ai_provider || "anthropic"
  rescue
    # During startup or if DB not ready, fall back to anthropic
    _ -> "anthropic"
  end

  @openrouter_model_cache_key "openrouter_sonnet_model"
  @openrouter_fallback_model "anthropic/claude-sonnet-4-20250514"

  defp openrouter_model do
    case Cache.get(@openrouter_model_cache_key, 86400) do
      nil -> discover_openrouter_model()
      cached -> {:ok, cached}
    end
  end

  defp discover_openrouter_model do
    with {:ok, api_key} <- openrouter_api_key() do
      req =
        Req.new(
          url: "https://openrouter.ai/api/v1/models",
          headers: [{"authorization", "Bearer #{api_key}"}]
        )

      case Req.get(req) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          pick_openrouter_sonnet(models)

        _ ->
          Logger.warning("Could not fetch OpenRouter models, using fallback")
          Cache.put(@openrouter_model_cache_key, @openrouter_fallback_model)
          {:ok, @openrouter_fallback_model}
      end
    end
  end

  defp pick_openrouter_sonnet(models) do
    sonnet =
      models
      |> Enum.filter(fn m ->
        id = m["id"] || ""
        String.contains?(id, "sonnet") and String.starts_with?(id, "anthropic/")
      end)
      |> Enum.sort_by(fn m -> m["created"] || m["id"] end, :desc)
      |> List.first()

    model_id =
      case sonnet do
        %{"id" => id} -> id
        _ -> @openrouter_fallback_model
      end

    Logger.info("Selected OpenRouter model: #{model_id}")
    Cache.put(@openrouter_model_cache_key, model_id)
    {:ok, model_id}
  end

  @doc """
  Returns a user-facing error message for a missing API key,
  based on the currently configured provider.
  """
  def api_key_error_message do
    case current_provider() do
      "openrouter" ->
        "OPENROUTER_API_KEY not set. Add it to the .env file and restart the server."

      _ ->
        "ANTHROPIC_API_KEY not set. Add it to the .env file and restart the server."
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
