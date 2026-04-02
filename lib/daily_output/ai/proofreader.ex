defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.
  Uses tool_use for structured output to avoid JSON parsing issues.
  """

  require Logger

  alias DailyOutput.AI

  def proofread(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    focus_topic = Keyword.get(opts, :focus_topic)

    context_block =
      if context != "" do
        "\n\nAdditional context about the student:\n#{context}\n"
      else
        ""
      end

    focus_block =
      if focus_topic && focus_topic != "" do
        """

        The student chose to focus on this concept for this exercise: "#{focus_topic}"
        You MUST include a "focus_result" in your response.
        """
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
    The student is learning Swiss Standard German (Schweizer Hochdeutsch). Important:
    - Never use ß — always use ss (e.g. "dass" not "daß", "Strasse" not "Straße")
    - Prefer Swiss German standard terms (Velo not Fahrrad, Poulet not Hähnchen, Natel not Handy, Trottoir not Bürgersteig, parkieren not parken, etc.)
    - Use Swiss conventions for dates, numbers, and spelling where they differ from German German

    Calibrate your feedback to #{level} level:
    - Only flag errors that a #{level} student should know better
    - Don't flag advanced constructions they haven't learned yet
    - Focus on patterns that will help them progress from #{level} toward the next level

    IMPORTANT: Write ALL feedback text (annotations, commentary, encouragement) in #{feedback_lang}.
    #{context_block}#{focus_block}
    Use the provide_feedback tool to return your response.

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
    """

    with {:ok, client} <- AI.client() do
      case Anthropix.chat(client,
             model: AI.model(),
             system: system,
             messages: [
               %{role: "user", content: "Please proofread this journal entry:\n\n#{text}"}
             ],
             tools: [feedback_tool(focus_topic)],
             tool_choice: %{type: "tool", name: "provide_feedback"},
             max_tokens: 4096
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => input} when is_map(input) ->
              {:ok, normalize_feedback(input)}

            _ ->
              Logger.error("Proofreader: no tool_use block in response: #{inspect(content)}")
              {:error, :no_tool_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def feedback_tool(focus_topic) do
    base_properties = %{
      "annotated_text" => %{
        "type" => "string",
        "description" => "Full original text with [[id:original||corrected]] markers on errors"
      },
      "annotations" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "integer"},
            "explanation" => %{
              "type" => "string",
              "description" => "Very brief fix reason (5-10 words max)"
            }
          },
          "required" => ["id", "explanation"]
        }
      },
      "commentary" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "type" => %{
              "type" => "string",
              "enum" => ["pattern", "suggestion", "alternative"]
            },
            "text" => %{"type" => "string", "description" => "Detailed explanation"}
          },
          "required" => ["type", "text"]
        }
      },
      "encouragement" => %{
        "type" => "string",
        "description" => "Brief positive note"
      }
    }

    base_required = ["annotated_text", "annotations", "commentary", "encouragement"]

    {properties, required} =
      if focus_topic && focus_topic != "" do
        focus_prop = %{
          "focus_result" => %{
            "type" => "object",
            "properties" => %{
              "used" => %{
                "type" => "boolean",
                "description" => "Did the student attempt to use this concept?"
              },
              "correct" => %{
                "type" => "boolean",
                "description" => "If used, did they use it correctly?"
              },
              "comment" => %{
                "type" => "string",
                "description" => "Brief encouraging feedback about their use of this concept"
              }
            },
            "required" => ["used", "correct", "comment"]
          }
        }

        {Map.merge(base_properties, focus_prop), base_required ++ ["focus_result"]}
      else
        {base_properties, base_required}
      end

    %{
      name: "provide_feedback",
      description: "Provide proofreading feedback on the student's journal entry",
      input_schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      }
    }
  end

  @doc """
  Normalizes feedback fields, decoding any JSON strings that should be lists.
  Called both when saving new feedback and when loading from the database.
  """
  def normalize_feedback(nil), do: nil

  def normalize_feedback(feedback) do
    base = %{
      "annotated_text" => feedback["annotated_text"] || "",
      "annotations" => decode_if_string(feedback["annotations"]) || [],
      "commentary" => decode_if_string(feedback["commentary"]) || [],
      "encouragement" => feedback["encouragement"] || ""
    }

    if feedback["focus_result"] do
      Map.put(base, "focus_result", feedback["focus_result"])
    else
      base
    end
  end

  defp decode_if_string(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, decoded} -> decoded
      _ -> val
    end
  end

  defp decode_if_string(val), do: val
end
