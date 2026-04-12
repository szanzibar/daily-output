defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.
  Uses tool_use for structured output to avoid JSON parsing issues.
  """

  require Logger

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  def proofread(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    focus_topic = Keyword.get(opts, :focus_topic)
    profile = LanguageProfile.resolve(target)

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
        Evaluate focus usage by meaning, not by exact keyword matching:
        - Set used=true if the student attempted the concept in any valid variant (inflection, paraphrase, synonym, equivalent connector, or minor typo)
        - Set used=false only if there is no attempt anywhere in the text
        - Set correct=true only if used=true and usage is correct in context
        - If used=false, correct MUST be false
        - The comment MUST match the booleans; never praise correct usage when used=false
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

    language_conventions_block =
      if profile.conventions == [] do
        ""
      else
        """

        Language-specific conventions for #{profile.prompt_name}:
        #{LanguageProfile.conventions_block(profile)}
        """
      end

    system = """
    You are a #{profile.prompt_name} teacher proofreading a journal entry written by a #{native} speaker at CEFR level #{level}.#{language_conventions_block}

    Calibrate your feedback to #{level} level:
    - Only flag errors that a #{level} student should know better
    - Don't flag advanced constructions they haven't learned yet
    - Focus on patterns that will help them progress from #{level} toward the next level

    IMPORTANT: Write ALL feedback text (annotations, commentary, encouragement) in #{feedback_lang}.
    #{context_block}#{focus_block}
    Use the provide_feedback tool to return your response.
    IMPORTANT: The "annotations" and "commentary" fields MUST be JSON arrays, NOT strings.
    Return them as structured arrays of objects, never as a stringified JSON string.

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
    - focus_result booleans must be self-consistent with focus_result comment
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
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
                "description" =>
                  "Did the student attempt this concept anywhere in the text? true for inflections/paraphrases/synonyms; exact keyword match is not required"
              },
              "correct" => %{
                "type" => "boolean",
                "description" =>
                  "If used=true, did they use it correctly in context? Must be false when used=false"
              },
              "comment" => %{
                "type" => "string",
                "description" =>
                  "Brief encouraging feedback consistent with used/correct booleans"
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

    case feedback["focus_result"] |> decode_focus_result() |> normalize_focus_result() do
      nil -> base
      focus_result -> Map.put(base, "focus_result", focus_result)
    end
  end

  defp normalize_focus_result(nil), do: nil

  defp normalize_focus_result(%{} = result) do
    used = normalize_bool(Map.get(result, "used"))
    correct = normalize_bool(Map.get(result, "correct"))

    result
    |> Map.put("used", used)
    |> Map.put("correct", if(used, do: correct, else: false))
  end

  defp decode_focus_result(nil), do: nil

  defp decode_focus_result(%{} = result), do: result

  defp decode_focus_result(result) when is_list(result) do
    Enum.find(result, &is_map/1)
  end

  defp decode_focus_result(result) when is_binary(result) do
    trimmed = String.trim(result)

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} ->
        decoded

      {:ok, [%{} = first | _]} ->
        first

      _ ->
        parsed =
          trimmed
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> lenient_parse_object()

        if map_size(parsed) > 0, do: parsed, else: nil
    end
  end

  defp decode_focus_result(_), do: nil

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false

  defp normalize_bool(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "y" -> true
      "ja" -> true
      _ -> false
    end
  end

  defp normalize_bool(1), do: true
  defp normalize_bool(_), do: false

  defp decode_if_string(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        # The model sometimes returns arrays as strings with unescaped quotes
        # inside text values (e.g. German „App" where " is U+0022).
        # Jason can't parse these, so we split by object boundaries and
        # extract key-value pairs manually.
        lenient_parse_json_array(val)
    end
  end

  defp decode_if_string(val), do: val

  defp lenient_parse_json_array(str) do
    trimmed = str |> String.trim() |> String.trim_leading("[") |> String.trim_trailing("]")

    if String.trim(trimmed) == "" do
      []
    else
      trimmed
      |> String.split(~r/\}\s*,\s*\{/)
      |> Enum.map(&lenient_parse_object/1)
      |> Enum.filter(&(map_size(&1) > 0))
    end
  end

  defp lenient_parse_object(chunk) do
    chunk = chunk |> String.trim() |> String.trim_leading("{") |> String.trim_trailing("}")

    # Find all "key": positions
    key_positions =
      Regex.scan(~r/"(\w+)"\s*:\s*/, chunk, return: :index)
      |> Enum.map(fn [{full_start, full_len}, {key_start, key_len}] ->
        key = String.slice(chunk, key_start, key_len)
        value_start = full_start + full_len
        {key, value_start}
      end)

    key_positions
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{key, val_start}, idx}, acc ->
      # Value extends until the next key's pattern or end of chunk
      next_key_start =
        case Enum.at(key_positions, idx + 1) do
          {_, next_start} ->
            # Back up past the comma and whitespace before the next key
            chunk
            |> String.slice(0, next_start)
            |> String.replace(~r/,\s*"[^"]*"\s*:\s*\z/, "")
            |> String.length()

          nil ->
            String.length(chunk)
        end

      raw_value = String.slice(chunk, val_start, next_key_start - val_start) |> String.trim()

      value =
        cond do
          # Number
          Regex.match?(~r/\A\d+\z/, raw_value) ->
            String.to_integer(raw_value)

          # Boolean
          raw_value == "true" ->
            true

          raw_value == "false" ->
            false

          # String — strip surrounding quotes and clean up residual escapes
          String.starts_with?(raw_value, "\"") ->
            raw_value
            |> String.trim_leading("\"")
            |> String.trim_trailing("\"")
            |> String.replace("\\\"", "\"")

          true ->
            raw_value
        end

      Map.put(acc, key, value)
    end)
  end
end
