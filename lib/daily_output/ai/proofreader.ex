defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.

  The journal `proofread/2` and `assess_conversation/2` use tool_use for their richer,
  structured output (commentary, focus_result). The per-message `proofread_message/2` — by
  far the most frequent call — instead asks for self-contained text markers and parses them
  (see `parse_message_feedback/1`): no ~700-token tool schema on every chat message, and no
  separate annotations list for the model to keep in sync.
  """

  require Logger

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  # Error categories used to tag per-message corrections. They let us measure, at the end
  # of a conversation, which kinds of mistakes the student repeated vs. stopped making.
  @categories ~w(gender case verb word-order agreement preposition spelling vocabulary punctuation other)

  # A correction marker: [[before||after||type||explanation]]. The model emits these inline
  # (no tool schema, ~700 input tokens/message cheaper; no separate list to keep in sync).
  # parse_message_feedback/1 keeps them inline in annotated_text (the front end reads each
  # marker's own explanation) and also derives a flat annotations list for server-side stats.
  @marker ~r/\[\[([\s\S]*?)\]\]/

  @doc "The fixed set of correction categories used to tag per-message annotations."
  def categories, do: @categories

  # The correction-marker convention, shared by proofread/2 (journal) and proofread_message/2
  # (chat) so the two never drift. The model wraps each error in a self-contained marker;
  # parse_message_feedback/1 turns these back into the stored shape (plain markers + a derived
  # annotations list). Each caller adds its own "reproduce the entire X" framing around this.
  defp marker_rules(profile) do
    """
    Wrap each correction in a self-contained marker with four ||-separated fields:

    [[before||after||type||explanation]]

    - before — the student's exact words (leave empty to insert something missing)
    - after — your correction (leave empty to delete something extra)
    - type — one of {#{Enum.join(@categories, ", ")}}
    - explanation — 5-10 words, in #{profile.prompt_name}, on what was wrong

    Why the format is exact: each marker is rendered inline so the student sees your fix in place against what they wrote, and the type field is tallied across entries to track which mistakes they keep making and which they've mastered. A malformed marker breaks both the display and the tracking, so keep the four fields and the «||» separators intact, and never nest «]]» inside a marker.

    Format example — the same markup applies to #{profile.prompt_name}; here one word is replaced, one inserted, one comma deleted:
    Ich [[hab||habe||verb||1. Person braucht «habe»]] gestern [[||wohl||vocabulary||«wohl» klingt natürlicher]] zu viel[[,||||punctuation||hier kein Komma]] gegessen.

    Keep markers tight and faithful to the text:
    - One marker fixes one thing; a swap, an insertion and a deletion are separate markers. Prefer a few small markers over one wide rewrite.
    - Mark the smallest span that fixes the error; leave every already-correct word outside the marker.
    - Go wide only when words genuinely move (word order) or a whole phrase is wrong (e.g. a literal calque from the student's own language) — even then, stop at the first and last word that actually changes.
    - If the student wrote a foreign word or a «(…?)» placeholder instead of #{profile.prompt_name}, supply the correct word.
    - Keep everything outside markers identical to the student's text — same words, punctuation and line breaks, including blank lines between paragraphs.

    Before you finish, re-read the student's original once against your output and check your own work: you caught the real errors and unnatural phrasing (not nitpicks), the text outside every marker is exactly the student's own words, and each marker has all four ||-fields and closes with ]]. Fix anything that doesn't hold.\
    """
  end

  # The substantive goal shared by the journal and chat correctors — WHAT to correct, not how
  # to format it. Beyond outright errors we explicitly want non-idiomatic phrasing flagged (the
  # "understandable, but a native wouldn't say it" case a purely error-hunting prompt drops),
  # while staying balanced and calibrated to the learner's level so we don't drown them.
  defp correction_goal(profile, native, level) do
    """
    Your job is to help the student speak correct, natural, idiomatic #{profile.prompt_name} — the way a native speaker actually says it. Correct two kinds of things, and treat them as equally important:
    - Outright errors — grammar, agreement, case, gender, word order, verb forms, spelling, wrong words.
    - Unnatural phrasing — wording that is understandable but that a native speaker wouldn't use: a literal translation from #{native}, an awkward word choice, a stiff preposition or word order. Do NOT skip these because the meaning is clear; they are what the student most needs to learn.

    Be thorough but balanced, and tailor to a CEFR #{level} learner: mark the errors and unnatural phrasing that will help them progress — common mistakes included — but don't nitpick, don't flag constructions clearly above their level, and leave anything already correct and natural untouched. Never invent errors.\
    """
  end

  # Shared prompt text for the focus-concept judgement, used by both the journal review and
  # the end-of-conversation review. `scope` is the noun for the thing being judged ("entry"
  # or "conversation"). Empty when no focus concept was set.
  defp focus_instructions(focus_topic, _scope) when focus_topic in [nil, ""], do: ""

  defp focus_instructions(focus_topic, scope) do
    """

    The student chose to focus on this concept for this #{scope}: «#{focus_topic}»
    You MUST include a focus_result. Judge focus usage by meaning, not exact keywords:
    - used=true if they attempted the concept in any valid variant (inflection, paraphrase, synonym, equivalent connector, minor typo)
    - used=false only if there is no attempt anywhere in the #{scope}
    - correct=true only if used=true and the usage is correct in context
    - if used=false, correct MUST be false; the comment MUST match the booleans, never praising correct usage when used=false
    """
  end

  # Shared definition of what "commentary" is, so the journal and conversation reviews ask
  # for the same thing.
  defp commentary_instruction do
    "AT MOST 2 pattern-level teaching points the student can turn into a future focus area, one short sentence each (max ~15 words), grounded in patterns the student actually repeated — a summary of the highest-value patterns, NOT a restatement of each correction. Return fewer or none if nothing pattern-level is worth practising."
  end

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

    focus_block = focus_instructions(focus_topic, "entry")

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

    #{correction_goal(profile, native, level)}

    Return your response with the provide_feedback tool:
    1. "annotated_text" — the ENTIRE original entry reproduced verbatim (preserve all line breaks), with each correction wrapped in a marker (format below).
    2. "commentary" — #{commentary_instruction()}

    #{marker_rules(profile)}

    Write ALL text (inside markers and in commentary) in #{feedback_lang}.
    #{context_block}#{focus_block}
    The "commentary" field MUST be a JSON array of objects, never a stringified string.
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [
               %{role: "user", content: "Please proofread this journal entry:\n\n#{text}"}
             ],
             tools: [feedback_tool(focus_topic)],
             tool_choice: %{type: "tool", name: "provide_feedback"},
             purpose: "proofread",
             # A long entry reproduced verbatim + many inline markers + commentary can exceed
             # 2048 and truncate the *later* corrections — which reads as "fewer corrections".
             max_tokens: 4096
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => input} when is_map(input) ->
              # annotated_text carries the shared inline markers; derive annotations from them
              # (guarded against the entry) so journal and chat share one correction path.
              marked =
                if is_binary(input["annotated_text"]) and input["annotated_text"] != "",
                  do: input["annotated_text"],
                  else: text

              corrections = parse_message_feedback(marked, text)
              {:ok, normalize_feedback(Map.merge(input, corrections))}

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
  re-correct text. It only does the wrap-up work: distill at most 2 pattern-level teaching
  points the student can turn into future focus areas (`commentary`), and judge whether the
  focus concept was used (`focus_result`).

  `messages` is the full transcript as a list of `%{role, body, feedback}` — each user
  message's `feedback` (its inline corrections) is summarised into the prompt so the
  review is grounded in the mistakes that actually happened, without re-finding them.

  Returns `{:ok, %{"commentary" => [...], "focus_result" => ...}}`
  (no `annotated_text`/`annotations`/`encouragement`) or `{:error, reason}`.
  """
  def assess_conversation(messages, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    focus_topic = Keyword.get(opts, :focus_topic)
    profile = LanguageProfile.resolve(target)

    feedback_lang = if level in ["B2", "C1", "C2"], do: target, else: native

    context_block =
      if context != "", do: "\n\nAdditional context about the student:\n#{context}\n", else: ""

    focus_block = focus_instructions(focus_topic, "conversation")

    system = """
    You are a #{profile.prompt_name} teacher reviewing a finished casual conversation a #{native} speaker (CEFR level #{level}) just had.

    The student's individual messages were ALREADY corrected inline as they were sent. Do NOT correct or rewrite their text again — that work is done.

    Your only job is to distill future focus areas:
    - "commentary": #{commentary_instruction()}
    - If a focus concept was set, also judge whether they used it (focus_result).

    Calibrate to #{level}: pick what will move them toward the next level.
    Write ALL text in #{feedback_lang}.
    #{context_block}#{focus_block}
    Use the provide_assessment tool. "commentary" MUST be a JSON array of objects, never a stringified string; each "type" is "pattern", "suggestion", or "alternative".
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: assessment_transcript(messages, profile)}],
             tools: [assessment_tool(focus_topic)],
             tool_choice: %{type: "tool", name: "provide_assessment"},
             purpose: "assessment",
             max_tokens: 512
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

    #{correction_goal(profile, native, level)}

    This is spoken-style chat, so don't flag informal register or contractions that are normal in speech — but DO flag phrasing that isn't idiomatic.

    Write ALL explanation text in #{feedback_lang}.
    #{context_block}
    OUTPUT FORMAT — output ONLY the corrected message, nothing else (no preamble, no JSON, no separate list). Reproduce the ENTIRE original message verbatim (keep all line breaks), wrapping each correction in a marker as below. If the message is already correct and natural, return it completely unchanged with no markers.

    #{marker_rules(profile)}
    """

    transcript = context_transcript(history, profile)

    user_content =
      transcript <>
        "The student just sent this message — correct only this message:\n\n#{text}"

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: user_content}],
             purpose: "proofread_message",
             # claude-sonnet-5 thinks (adaptively) by default, and this Anthropix version can't
             # pass output_config.effort to rein it in. At 1024 a hard think ate the whole budget
             # and no correction text was emitted (max_tokens hit mid-thought → :no_text_response).
             # Adaptive thinking sizes to difficulty, so the headroom below lets it finish AND
             # still emit the correction; output is billed by real usage, so short calls cost the same.
             max_tokens: 4096
           ) do
        {:ok, %{"content" => content}} when is_list(content) ->
          case content
               |> Enum.filter(&(&1["type"] == "text"))
               |> Enum.map_join("", & &1["text"]) do
            "" ->
              Logger.error("proofread_message: empty text response: #{inspect(content)}")
              {:error, :no_text_response}

            output ->
              {:ok, normalize_message_feedback(parse_message_feedback(output, text))}
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
      |> Enum.take(-2)
      |> Enum.map_join("\n", fn msg ->
        speaker = if msg.role == "user", do: "Student", else: "Partner (#{profile.prompt_name})"
        "#{speaker}: #{msg.body}"
      end)

    "Conversation so far (for context only — do NOT correct these):\n#{lines}\n\n"
  end

  @doc """
  Parses a proofread response into `%{"annotated_text", "annotations"}`.

  The model emits self-contained markers `[[before||after||type||explanation]]`. We keep them
  inline in `annotated_text` (the front end reads each marker's own explanation, so there is no
  id to match) and also derive a flat `annotations` list (`type` + `explanation`) for the
  server-side stats that count which mistakes repeat. No-op markers (before == after — the model
  flagging then keeping text) are dropped back to plain text.
  """
  def parse_message_feedback(text) when is_binary(text) do
    %{"annotated_text" => render_markers(text), "annotations" => derive_annotations(text)}
  end

  def parse_message_feedback(_), do: %{"annotated_text" => "", "annotations" => []}

  @doc """
  Parses `output` and guards it against the known `original` message.

  The one way the model misbehaves on ambiguous sentences is rambling/retracting in prose
  (e.g. «actually this is correct…»), which injects a run of words the student never wrote.
  We reduce every marker to its `before` side and reject only when several consecutive words
  are foreign to `original`; isolated duplicates or spacing artifacts from many corrections are
  fine, so a long, heavily-marked entry is not thrown away over one quirk.
  """
  def parse_message_feedback(output, original) when is_binary(output) and is_binary(original) do
    parsed = parse_message_feedback(output)

    if uncontaminated?(parsed["annotated_text"], original) do
      parsed
    else
      Logger.warning(
        "proofread: output injected prose the student never wrote; showing it uncorrected. output=#{inspect(output)}"
      )

      %{"annotated_text" => original, "annotations" => []}
    end
  end

  # Keep real markers inline, verbatim; drop a no-op marker (before == after) to plain text.
  defp render_markers(text) do
    @marker
    |> Regex.replace(text, fn whole, inner ->
      case marker_parts(inner) do
        {before, after_, _type, _expl} when before == after_ -> before
        _ -> whole
      end
    end)
    |> String.trim()
  end

  defp derive_annotations(text) do
    @marker
    |> Regex.scan(text)
    |> Enum.flat_map(fn [_, inner] ->
      case marker_parts(inner) do
        {before, after_, type, explanation} when before != after_ ->
          [%{"category" => normalize_category(type), "explanation" => String.trim(explanation)}]

        _ ->
          []
      end
    end)
  end

  # Inner of a marker -> {before, after, type, explanation}, or :malformed when there's no ||.
  # Missing trailing fields default so a 2- or 3-field marker still parses.
  defp marker_parts(inner) do
    case String.split(inner, "||", parts: 4) do
      [before, after_, type, explanation] -> {before, after_, type, explanation}
      [before, after_, type] -> {before, after_, type, ""}
      [before, after_] -> {before, after_, "other", ""}
      _ -> :malformed
    end
  end

  # Reduce markers to the student's original words; clean output has no run of foreign words.
  # Injected prose is a contiguous run of words absent from the source; isolated artifacts are not.
  @max_foreign_run 3
  defp uncontaminated?(annotated_text, original) do
    source = MapSet.new(words(original))

    reduced =
      Regex.replace(@marker, annotated_text, fn whole, inner ->
        case marker_parts(inner) do
          {before, _after, _type, _expl} -> before
          :malformed -> whole
        end
      end)

    longest_foreign_run(words(reduced), source) <= @max_foreign_run
  end

  defp longest_foreign_run(words, source) do
    {max, _run} =
      Enum.reduce(words, {0, 0}, fn word, {max, run} ->
        if MapSet.member?(source, word),
          do: {max, 0},
          else: {max(max, run + 1), run + 1}
      end)

    max
  end

  defp words(text), do: text |> String.downcase() |> String.split(~r/\s+/, trim: true)

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
    base = %{
      "annotated_text" => %{
        "type" => "string",
        "description" =>
          "The full original entry reproduced verbatim (keep all line breaks), with [[before||after||type||explanation]] markers on errors"
      },
      "commentary" => commentary_schema()
    }

    {properties, required} =
      with_focus_result(base, ["annotated_text", "commentary"], focus_topic)

    %{
      name: "provide_feedback",
      description: "Provide proofreading feedback on the student's journal entry",
      input_schema: %{"type" => "object", "properties" => properties, "required" => required}
    }
  end

  @doc false
  def assessment_tool(focus_topic) do
    {properties, required} =
      with_focus_result(%{"commentary" => commentary_schema()}, ["commentary"], focus_topic)

    %{
      name: "provide_assessment",
      description:
        "Provide the end-of-conversation review (future focus areas + focus result). Do NOT correct text.",
      input_schema: %{"type" => "object", "properties" => properties, "required" => required}
    }
  end

  # commentary + focus_result are identical for the journal review (feedback_tool) and the
  # end-of-conversation review (assessment_tool), so both build from these shared fragments.
  defp commentary_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ["pattern", "suggestion", "alternative"]},
          "text" => %{
            "type" => "string",
            "description" =>
              "One pattern-level teaching point to turn into a focus area — one short sentence, max ~15 words"
          }
        },
        "required" => ["type", "text"]
      }
    }
  end

  defp focus_result_schema do
    %{
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
  end

  defp with_focus_result(properties, required, focus_topic) do
    if focus_topic && focus_topic != "" do
      {Map.put(properties, "focus_result", focus_result_schema()), required ++ ["focus_result"]}
    else
      {properties, required}
    end
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
