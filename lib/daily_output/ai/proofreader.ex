defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.
  Uses tool_use for structured output to avoid JSON parsing issues.
  """

  require Logger

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  # Error categories used to tag per-message corrections. They let us measure, at the end
  # of a conversation, which kinds of mistakes the student repeated vs. stopped making.
  @categories ~w(gender case verb word-order agreement preposition spelling vocabulary punctuation other)

  @doc "The fixed set of correction categories used to tag per-message annotations."
  def categories, do: @categories

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

    RULES for annotated_text — getting the marker STRUCTURE right matters above all:
    - Reproduce the ENTIRE original text, preserving all original line breaks; mark only real errors
    - A marker is EXACTLY: [[N:original||corrected]]
      • N is a plain counting number (1, 2, 3, …) and MUST equal that correction's "id" in annotations
      • There is EXACTLY ONE colon, right after N — never the literal letters "id", never two numbers or colons
        ✗ WRONG: [[id:das||dass]]   ✗ WRONG: [[id:1:das||dass]]   ✓ RIGHT: [[1:das||dass]]
    - Every correction is exactly ONE of three forms — choose the one that matches:
      • REPLACE a wrong word/phrase: [[1:wrong||right]] (BOTH sides filled), e.g. [[1:das||dass]]
      • INSERT something missing: [[2:||missing]] (original side EMPTY), e.g. a missing comma is [[2:||,]]
      • DELETE something extra: [[3:extra||]] (corrected side EMPTY)
    - A wrong word is always a REPLACE — never leave the right side empty
    - A missing word or punctuation is always an INSERT — leave the original side empty, never repeat the neighbouring word
    - Mark the SMALLEST span that fixes the error; do NOT rewrite correct text
    - Each N should be unique — do not reuse the same id for different corrections
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

  @doc """
  End-of-conversation review — runs once when the student hits "Done".

  Individual messages are already corrected inline as they are sent, so this does NOT
  re-correct text. It only does the wrap-up work: judge whether the focus concept was
  used (`focus_result`), distill a few teaching points the student can turn into future
  focus areas (`commentary`), and write a short encouraging note (`encouragement`).

  `messages` is the full transcript as a list of `%{role, body, feedback}` — each user
  message's `feedback` (its inline corrections) is summarised into the prompt so the
  review is grounded in the mistakes that actually happened, without re-finding them.

  Returns `{:ok, %{"commentary" => [...], "encouragement" => ..., "focus_result" => ...}}`
  (no `annotated_text`/`annotations`) or `{:error, reason}`.
  """
  def assess_conversation(messages, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    focus_topic = Keyword.get(opts, :focus_topic)
    improvement = Keyword.get(opts, :improvement)
    profile = LanguageProfile.resolve(target)

    feedback_lang = if level in ["B2", "C1", "C2"], do: target, else: native

    context_block =
      if context != "", do: "\n\nAdditional context about the student:\n#{context}\n", else: ""

    improvement_block = improvement_block(improvement, feedback_lang)

    focus_block =
      if focus_topic && focus_topic != "" do
        """

        The student chose to focus on this concept for this conversation: "#{focus_topic}"
        You MUST include a "focus_result" in your response.
        Judge focus usage by meaning, not exact keywords:
        - used=true if they attempted the concept in any valid variant (inflection, paraphrase, synonym, equivalent connector, minor typo)
        - used=false only if there is no attempt anywhere in the conversation
        - correct=true only if used=true and the usage is correct in context
        - if used=false, correct MUST be false; the comment MUST match the booleans
        """
      else
        ""
      end

    system = """
    You are a #{profile.prompt_name} teacher reviewing a finished casual conversation a #{native} speaker (CEFR level #{level}) just had.

    The student's individual messages were ALREADY corrected inline as they were sent. Do NOT correct or rewrite their text again — that work is done.

    Your job is the end-of-conversation review:
    - If a focus concept was set, judge whether they used it (focus_result).
    - Distill 2-4 concrete teaching points ("commentary") the student can turn into future focus areas — grounded in the mistakes they actually made and any patterns repeated across the chat. Prefer patterns over one-offs.
    - Write one short encouraging note ("encouragement") about how the conversation went.
    - If an improvement signal is provided below, add a one-sentence "improvement_note" narrating that within-conversation progress.

    Calibrate to #{level}: focus on what will move them toward the next level.
    IMPORTANT: Write ALL text in #{feedback_lang}.
    In any text NEVER use the double-quote character (") — use «guillemets» or 'single quotes'.
    #{context_block}#{focus_block}#{improvement_block}
    Use the provide_assessment tool to return your response.
    IMPORTANT: "commentary" MUST be a JSON array of objects, never a stringified JSON string.
    commentary "type" must be "pattern", "suggestion", or "alternative".
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: assessment_transcript(messages, profile)}],
             tools: [assessment_tool(focus_topic)],
             tool_choice: %{type: "tool", name: "provide_assessment"},
             max_tokens: 2048
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => input} when is_map(input) ->
              {:ok, normalize_feedback(input)}

            _ ->
              Logger.error("assess_conversation: no tool_use block: #{inspect(content)}")
              {:error, :no_tool_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A compact, already-computed improvement signal the model narrates into improvement_note.
  defp improvement_block(nil, _lang), do: ""

  defp improvement_block(analysis, lang) do
    resolved = analysis["resolved_categories"] || []
    repeated = analysis["repeated_categories"] || []

    """

    Improvement signal already computed for THIS conversation (narrate it in improvement_note):
    - Mistake categories the student stopped repeating after being corrected: #{fmt_categories(resolved)}
    - Categories still being repeated: #{fmt_categories(repeated)}
    - Correction rate per 100 words: early #{fmt_rate(analysis["early_rate"])} → late #{fmt_rate(analysis["late_rate"])}
    Write improvement_note as one short, honest, encouraging sentence (in #{lang}) about this progress. If there is nothing meaningful to say, use an empty string.
    """
  end

  defp fmt_categories([]), do: "(none)"
  defp fmt_categories(list), do: Enum.join(list, ", ")

  defp fmt_rate(nil), do: "n/a"
  defp fmt_rate(rate), do: to_string(rate)

  # The full transcript, with each student message's already-applied corrections summarised
  # below it (category: explanation) so the review is grounded without re-correcting.
  defp assessment_transcript(messages, profile) do
    lines =
      Enum.map_join(messages, "\n", fn msg ->
        speaker = if msg.role == "user", do: "Student", else: "Partner (#{profile.prompt_name})"
        base = "#{speaker}: #{msg.body}"

        case msg.role == "user" && corrections_summary(msg) do
          summary when is_binary(summary) and summary != "" ->
            base <> "\n  (corrections already given — #{summary})"

          _ ->
            base
        end
      end)

    "The finished conversation (each student message was already corrected inline):\n#{lines}\n"
  end

  defp corrections_summary(%{feedback: %{"annotations" => anns}}) when is_list(anns) do
    anns
    |> Enum.map(fn a -> "#{a["category"]}: #{a["explanation"]}" end)
    |> Enum.reject(&(&1 == ": "))
    |> Enum.join("; ")
  end

  defp corrections_summary(_), do: ""

  @doc """
  Proofreads a single conversation message, right after the student sends it.

  Unlike `proofread/2` (a journal entry) this is calibrated for casual chat: it only
  flags real grammar/usage/spelling errors, never informal register, and each correction
  is tagged with a `category` so we can later measure improvement within the conversation.
  Prior turns are passed via `:context_messages` (a list of `%{role, body}`) so the model
  understands what the student is replying to, but it corrects ONLY the latest message.

  Returns `{:ok, %{"annotated_text" => ..., "annotations" => [...]}}` or `{:error, reason}`.
  """
  def proofread_message(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    history = Keyword.get(opts, :context_messages, [])
    profile = LanguageProfile.resolve(target)

    feedback_lang = if level in ["B2", "C1", "C2"], do: target, else: native

    context_block =
      if context != "", do: "\n\nAdditional context about the student:\n#{context}\n", else: ""

    language_conventions_block =
      if profile.conventions == [] do
        ""
      else
        "\n\nLanguage-specific conventions for #{profile.prompt_name}:\n#{LanguageProfile.conventions_block(profile)}\n"
      end

    system = """
    You are a #{profile.prompt_name} teacher correcting one message a #{native} speaker (CEFR level #{level}) just sent in a casual chat.#{language_conventions_block}

    This is spoken-style conversation, not formal writing. Calibrate to #{level}:
    - Only flag genuine errors a #{level} student should know better (grammar, agreement, case, gender, word order, verb forms, spelling, clearly wrong word choice)
    - Do NOT flag casual/colloquial register, contractions, or stylistic choices that are acceptable in speech
    - Do NOT flag advanced constructions they haven't learned yet
    - If the message is already correct, return it unchanged with an empty annotations array

    IMPORTANT: Write ALL explanation text in #{feedback_lang}.
    #{context_block}
    Use the provide_corrections tool to return your response.
    IMPORTANT: "annotations" MUST be a JSON array of objects, never a stringified JSON string.

    Getting the marker STRUCTURE right matters more than catching every nuance.
    Reproduce the ENTIRE original message (preserving line breaks) and mark only real errors.

    A marker is EXACTLY: [[N:original||corrected]]
    - N is a plain counting number: 1 for the first correction, 2 for the second, and so on.
      It MUST equal that correction's "id" in the annotations array.
    - There is EXACTLY ONE colon, right after N. Then the original text, then ||, then the corrected text.
    - NEVER write the literal letters "id". NEVER put two numbers or two colons before the text.
      ✗ WRONG: [[id:das||dass]]   ✗ WRONG: [[id:1:das||dass]]   ✗ WRONG: [[1:1:das||dass]]
      ✓ RIGHT: [[1:das||dass]]

    Every correction is exactly ONE of these three forms — choose the one that matches:
    - REPLACE a wrong word/phrase: [[1:wrong||right]] — BOTH sides filled, e.g. [[1:das||dass]]
    - INSERT something missing: [[2:||missing]] — original side EMPTY, e.g. a missing comma is [[2:||,]]
    - DELETE something extra: [[3:extra||]] — corrected side EMPTY

    So:
    - A wrong word is always a REPLACE — never leave the right side empty
    - A missing word or punctuation mark is always an INSERT — leave the original side empty, never repeat the neighbouring word
    - Mark the SMALLEST span that fixes the error; never restate correct text
    - Each N is unique; never put ]] inside a marker; use plain text only (no bracket characters)

    Keep each explanation VERY SHORT (5-10 words) — say what is wrong, not a grammar lecture.
    In explanations NEVER use the double-quote character (") — use «guillemets» or 'single quotes'.
    Tag each correction with the single best category from: #{Enum.join(@categories, ", ")}
    """

    transcript = context_transcript(history, profile)

    user_content =
      transcript <>
        "The student just sent this message — correct only this message:\n\n#{text}"

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: user_content}],
             tools: [message_feedback_tool()],
             tool_choice: %{type: "tool", name: "provide_corrections"},
             max_tokens: 1024
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => input} when is_map(input) ->
              {:ok, normalize_message_feedback(input)}

            _ ->
              Logger.error("proofread_message: no tool_use block: #{inspect(content)}")
              {:error, :no_tool_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A short transcript of the preceding turns, so the model can judge the latest message
  # in context (e.g. what question it answers) without correcting the earlier turns.
  defp context_transcript([], _profile), do: ""

  defp context_transcript(history, profile) do
    lines =
      history
      |> Enum.take(-6)
      |> Enum.map_join("\n", fn msg ->
        speaker = if msg.role == "user", do: "Student", else: "Partner (#{profile.prompt_name})"
        "#{speaker}: #{msg.body}"
      end)

    "Conversation so far (for context only — do NOT correct these):\n#{lines}\n\n"
  end

  @doc false
  def message_feedback_tool do
    %{
      name: "provide_corrections",
      description: "Provide inline corrections for the student's latest chat message",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "annotated_text" => %{
            "type" => "string",
            "description" =>
              "The full original message with [[N:original||corrected]] markers on errors"
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
                },
                "category" => %{
                  "type" => "string",
                  "enum" => @categories,
                  "description" => "The single best category for this error"
                }
              },
              "required" => ["id", "explanation", "category"]
            }
          }
        },
        "required" => ["annotated_text", "annotations"]
      }
    }
  end

  @doc """
  Normalizes per-message feedback to `%{"annotated_text", "annotations"}`.

  We rely on the tool schema + prompt to return a clean structured array, so this only
  shapes/validates the structured result; it does NOT try to recover a mangled response.
  Anything that isn't a list of maps yields no annotations rather than garbage.
  """
  def normalize_message_feedback(nil), do: nil

  def normalize_message_feedback(feedback) do
    %{
      "annotated_text" => feedback["annotated_text"] || "",
      "annotations" => normalize_annotations(feedback["annotations"])
    }
  end

  defp normalize_annotations(annotations) when is_list(annotations) do
    annotations
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn ann ->
      %{
        "id" => ann["id"],
        "explanation" => to_string(ann["explanation"] || ""),
        "category" => normalize_category(ann["category"])
      }
    end)
  end

  defp normalize_annotations(_), do: []

  defp normalize_category(cat) when is_binary(cat) do
    normalized = cat |> String.trim() |> String.downcase()
    if normalized in @categories, do: normalized, else: "other"
  end

  defp normalize_category(_), do: "other"

  @doc false
  def feedback_tool(focus_topic) do
    base_properties = %{
      "annotated_text" => %{
        "type" => "string",
        "description" => "Full original text with [[N:original||corrected]] markers on errors"
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

  @doc false
  def assessment_tool(focus_topic) do
    base_properties = %{
      "commentary" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "enum" => ["pattern", "suggestion", "alternative"]},
            "text" => %{
              "type" => "string",
              "description" => "A concrete teaching point the student can turn into a focus area"
            }
          },
          "required" => ["type", "text"]
        }
      },
      "encouragement" => %{
        "type" => "string",
        "description" => "One short, specific positive note about the conversation"
      },
      "improvement_note" => %{
        "type" => "string",
        "description" =>
          "One sentence narrating the within-conversation improvement signal, or empty string if none was provided"
      }
    }

    base_required = ["commentary", "encouragement"]

    {properties, required} =
      if focus_topic && focus_topic != "" do
        focus_prop = %{
          "focus_result" => %{
            "type" => "object",
            "properties" => %{
              "used" => %{
                "type" => "boolean",
                "description" =>
                  "Did the student attempt this concept anywhere? true for inflections/paraphrases/synonyms; exact keyword match is not required"
              },
              "correct" => %{
                "type" => "boolean",
                "description" =>
                  "If used=true, did they use it correctly in context? Must be false when used=false"
              },
              "comment" => %{
                "type" => "string",
                "description" => "Brief feedback consistent with used/correct booleans"
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
      name: "provide_assessment",
      description:
        "Provide the end-of-conversation review (focus result, teaching points, encouragement). Do NOT correct text.",
      input_schema: %{"type" => "object", "properties" => properties, "required" => required}
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

    base
    |> put_focus_result(feedback)
    |> put_optional("improvement_note", feedback["improvement_note"])
    |> put_optional("improvement", feedback["improvement"])
  end

  defp put_focus_result(base, feedback) do
    case feedback["focus_result"] |> decode_focus_result() |> normalize_focus_result() do
      nil -> base
      focus_result -> Map.put(base, "focus_result", focus_result)
    end
  end

  # Carry an optional field through normalization only when it actually has content.
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

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
