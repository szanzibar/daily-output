defmodule DailyOutput.AI.TopicGenerator do
  @moduledoc """
  Generates conversation openers for the role-play feature.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  def generate_openers(topics, target_language, native_language) do
    topic_list =
      case topics do
        [] -> "Alltag, Arbeit, Hobbys, Essen, Reisen, Wetter"
        list -> Enum.join(list, ", ")
      end

    profile = LanguageProfile.resolve(target_language)

    locale_line =
      if profile.locale_context do
        "These are things a friend #{profile.locale_context} might say to start a casual conversation."
      else
        "These are things a friend might say to start a casual conversation."
      end

    conventions_block =
      if profile.conventions == [] do
        ""
      else
        LanguageProfile.conventions_block(profile) <> "\n"
      end

    system = """
    Generate exactly 4 natural conversation openers in #{profile.prompt_name}.
    #{locale_line}
    #{conventions_block}

    Topics to draw from: #{topic_list}

    Each opener should:
    - Be a natural question or statement a native #{profile.prompt_name} speaker would use
    - Be 1-2 sentences max
    - Range from easier to more challenging vocabulary
    - Include a #{native_language} translation

    Respond with ONLY a JSON array:
    [{"opener": "Wie war dein Wochenende?", "translation": "How was your weekend?"}]
    No other text.
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: "Generate 4 conversation openers."}],
             max_tokens: 1024
           ) do
        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          parse_openers(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_openers(text) do
    case Regex.run(~r/\[[\s\S]*\]/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, openers} when is_list(openers) -> {:ok, openers}
          _ -> {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end
end
