defmodule Sprachjournal.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.
  """

  alias Sprachjournal.AI

  def proofread(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")

    context_block =
      if context != "" do
        "\n\nAdditional context about the student:\n#{context}\n"
      else
        ""
      end

    # B2+ students get all feedback in the target language
    feedback_lang =
      if level in ["B2", "C1", "C2"] do
        target
      else
        native
      end

    system = """
    You are a #{target} teacher proofreading a journal entry written by a #{native} speaker at CEFR level #{level}.

    Calibrate your feedback to #{level} level:
    - Only flag errors that a #{level} student should know better
    - Don't flag advanced constructions they haven't learned yet
    - Focus on patterns that will help them progress from #{level} toward the next level

    IMPORTANT: Write ALL feedback text (annotations, commentary, encouragement) in #{feedback_lang}.
    #{context_block}
    Respond with ONLY a JSON object:
    {
      "annotated_text": "full text with [[id:original||corrected]] markers on errors",
      "annotations": [{"id": 1, "explanation": "very brief fix reason in #{feedback_lang} (5-10 words max)"}],
      "commentary": [{"type": "pattern", "text": "detailed explanation in #{feedback_lang}"}],
      "encouragement": "brief positive note in #{feedback_lang}"
    }

    RULES for annotated_text:
    - Reproduce the ENTIRE original text, preserving all original line breaks
    - Only mark actual errors with [[id:original||corrected]]
    - Do NOT rewrite correct text
    - For insertions (adding a missing word), use [[id:||word]] with empty original
    - For deletions (removing a word), use [[id:word||]] with empty corrected
    - Each id should be unique — do not reuse the same id for different corrections
    - NEVER put ]] inside a marker — the marker must end with exactly ]]
    - Both original and corrected text should be simple text with no special bracket characters
    - Keep annotation explanations VERY SHORT (5-10 words)
    - Put longer explanations and teaching points in "commentary" instead
    - commentary type can be "pattern", "suggestion", or "alternative"
    - Respond with ONLY the JSON. No other text.
    """

    with {:ok, client} <- AI.client() do
      case Anthropix.chat(client,
             model: AI.model(),
             system: system,
             messages: [
               %{role: "user", content: "Please proofread this journal entry:\n\n#{text}"}
             ],
             max_tokens: 4096
           ) do
        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          parse_feedback(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_feedback(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, feedback} when is_map(feedback) ->
            {:ok, normalize_feedback(feedback)}

          _ ->
            {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end

  defp normalize_feedback(feedback) do
    %{
      "annotated_text" => feedback["annotated_text"] || "",
      "annotations" => feedback["annotations"] || [],
      "commentary" => feedback["commentary"] || [],
      "encouragement" => feedback["encouragement"] || ""
    }
  end
end
