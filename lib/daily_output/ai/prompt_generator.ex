defmodule DailyOutput.AI.PromptGenerator do
  @moduledoc """
  Generates contextual writing prompts for journal entries.
  """

  alias DailyOutput.AI

  def generate_prompts(topics, target_language, native_language) do
    # None, one, or two seeds drawn at random from the learner's interests.
    # `[]` (some days) means no injected theme at all, so the model is free to roam.
    inspiration_block =
      case Enum.take_random(topics, Enum.random(0..2)) do
        [] ->
          "Today, don't anchor on any given theme — roam freely across everyday moments,
          opinions, memories, small decisions, hypotheticals, and the occasional bigger question."

        seeds ->
          "As loose inspiration for only one or two of the prompts (not a checklist — come at them " <>
            "from an unexpected angle): #{Enum.join(seeds, "; ")}. Let the remaining prompts " <>
            "roam well beyond these."
      end

    system = """
    You are a creative writing-prompt generator for a journal-keeping language learner.
    The student speaks #{native_language} and is learning #{target_language}.

    Generate exactly 5 writing prompts. Prize VARIETY and creative range — surprise the
    student with angles they wouldn't think of themselves, while keeping every prompt
    rooted in a real life they could plausibly live.

    #{inspiration_block}
    - Vary the depth deliberately — mostly light and concrete, but include the odd
      reflective or thought-provoking prompt about values, choices, or how things change.
    - Keep each prompt answerable from personal experience and concrete enough to write
      about — never an abstract essay topic.
    - Range from easier to more challenging language.

    Each prompt is written in #{target_language} with a #{native_language} translation.

    Respond with ONLY a JSON array of objects, each with "prompt" and "translation" keys.
    Example: [{"prompt": "Was hast du heute zum Frühstück gegessen?", "translation": "What did you eat for breakfast today?"}]
    No other text, just the JSON array.
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             purpose: "prompts",
             system: system,
             messages: [%{role: "user", content: "Generate 5 writing prompts for today."}],
             max_tokens: 1024
           ) do
        {:ok, %{"content" => _} = response} ->
          parse_prompts(AI.text_content(response))

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
