defmodule DailyOutput.AI.PromptGenerator do
  @moduledoc """
  Generates contextual writing prompts for journal entries.
  """

  alias DailyOutput.AI

  def generate_prompts(topics, target_language, native_language) do
    topic_list =
      case topics do
        [] -> "everyday life, work, hobbies, food, travel, weather"
        list -> Enum.join(list, ", ")
      end

    system = """
    You are a language learning assistant. Generate exactly 4 writing prompts for a journal entry.
    The student speaks #{native_language} and is learning #{target_language}.

    The prompts should:
    - Be written in #{target_language} (with a #{native_language} translation in parentheses)
    - Be about topics relevant to daily life: #{topic_list}
    - Be concrete and specific, not abstract
    - Range from easier to more challenging
    - Encourage the student to use vocabulary they'd need in real conversations

    Respond with ONLY a JSON array of objects, each with "prompt" and "translation" keys.
    Example: [{"prompt": "Was hast du heute zum Frühstück gegessen?", "translation": "What did you eat for breakfast today?"}]
    No other text, just the JSON array.
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: "Generate 4 writing prompts for today."}],
             max_tokens: 1024
           ) do
        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          parse_prompts(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_prompts(text) do
    case Regex.run(~r/\[[\s\S]*\]/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, prompts} when is_list(prompts) -> {:ok, prompts}
          _ -> {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end
end
