defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI-powered proofreading with inline correction markers.

  Both the journal `proofread/2` and the per-message `proofread_message/2` ask the model, via
  tool_use, for a clean *rewrite* of the text plus a list of `{before, after, type,
  explanation}` changes — the model never hand-places `[[..]]` markers. `AI.RewriteDiff` then
  builds the inline markers deterministically from a word diff of original↔rewrite, so a
  malformed or garbled marker (the old failure on word-order moves) is impossible by
  construction. The stored shape is unchanged: `annotated_text` (inline markers) + a derived
  `annotations` list (see `parse_message_feedback/1`), which the front end, flashcards and
  stats all still read. `assess_conversation/2` does no correcting — only commentary + focus.
  """

  require Logger

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile
  alias DailyOutput.AI.RewriteDiff

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
    1. "corrected" — the ENTIRE entry rewritten correctly and naturally. Change ONLY what needs fixing; keep every correct word, all punctuation, and all line breaks (including the blank lines between paragraphs) identical. Do NOT add any markup.
    2. "corrections" — one entry per change, in the order the changes appear, each with "before" (the student's original words, empty if you inserted), "after" (your correction, empty if you deleted), "type" (one of {#{Enum.join(@categories, ", ")}}), and "explanation" (5-10 words on what was wrong). Every change in "corrected" has exactly one entry here.
    3. "commentary" — #{commentary_instruction()}

    Write ALL explanation text in #{feedback_lang}.
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
             # A full-entry rewrite + a change list + commentary; 4096 keeps a long entry from
             # truncating. max_tokens is a ceiling, not a cost (billed by real usage).
             max_tokens: 4096
           ) do
        {:ok, %{"content" => content} = response} ->
          case AI.tool_use(response) do
            input when is_map(input) ->
              # The model rewrites the entry + lists changes; RewriteDiff builds the inline
              # markers deterministically, so journal and chat share one garble-proof path.
              corrected =
                if is_binary(input["corrected"]) and input["corrected"] != "",
                  do: input["corrected"],
                  else: text

              annotated = RewriteDiff.annotate(text, corrected, decode_if_string(input["corrections"]) || [])
              corrections = parse_message_feedback(annotated, text)
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
        {:ok, %{"content" => content} = response} ->
          case AI.tool_use(response) do
            input when is_map(input) ->
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
    Use the report_corrections tool.
    1. "corrected" — the student's message rewritten exactly as a native speaker would say it. Change ONLY what needs fixing; keep everything else — every correct word, all punctuation, and all line breaks — identical. If the message is already correct and natural, return it completely unchanged.
    2. "corrections" — one entry per change, in the order the changes appear, each with:
       - "after": the corrected words as they appear in your rewrite (empty if you deleted something)
       - "before": the student's original words you changed (empty if you inserted something)
       - "type": one of {#{Enum.join(@categories, ", ")}}
       - "explanation": 5-10 words, in #{feedback_lang}, on what was wrong

    Do NOT place any markup inside "corrected" — just write the clean corrected message. The two fields must agree: every change in "corrected" has one entry in "corrections".
    """

    transcript = context_transcript(history, profile)

    user_content =
      transcript <>
        "The student just sent this message — correct only this message:\n\n#{text}"

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: user_content}],
             tools: [message_tool()],
             tool_choice: %{type: "tool", name: "report_corrections"},
             purpose: "proofread_message",
             # A rewrite of one chat message + a short change list; 1024 is plenty and caps a
             # runaway (a model with thinking off can occasionally loop). max_tokens is a
             # ceiling, not a cost — billed by real usage.
             max_tokens: 1024
           ) do
        {:ok, response} ->
          {:ok, normalize_message_feedback(build_message_feedback(response, text))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Turn the report_corrections tool call into the stored `%{annotated_text, annotations}`:
  # the model gives us a clean rewrite + a change list, and RewriteDiff builds the inline
  # markers deterministically (so a malformed/garbled marker is impossible). Falls back to the
  # uncorrected message if the tool call is missing/empty (e.g. a truncated runaway response).
  defp build_message_feedback(response, original) do
    case AI.tool_use(response) do
      %{"corrected" => corrected} = input when is_binary(corrected) and corrected != "" ->
        corrections = decode_if_string(input["corrections"]) || []
        annotated = RewriteDiff.annotate(original, corrected, corrections)
        parse_message_feedback(annotated, original)

      other ->
        Logger.warning("proofread_message: no usable tool call (#{inspect(other)}); leaving message uncorrected")
        %{"annotated_text" => original, "annotations" => []}
    end
  end

  # One change in a rewrite: the original span, its replacement, and why. Shared by the chat
  # tool (message_tool) and the journal tool (feedback_tool) so the two never drift. RewriteDiff
  # matches these back to the diff of original↔rewrite to build the inline markers.
  defp correction_item_schema do
    %{
      "type" => "object",
      "properties" => %{
        "after" => %{"type" => "string", "description" => "the corrected words as they appear in the rewrite (empty to delete)"},
        "before" => %{"type" => "string", "description" => "the student's original words that changed (empty to insert)"},
        "type" => %{"type" => "string", "enum" => @categories},
        "explanation" => %{"type" => "string", "description" => "5-10 words on what was wrong"}
      },
      "required" => ["after", "before", "type", "explanation"]
    }
  end

  @doc false
  def message_tool do
    %{
      name: "report_corrections",
      description: "Report the corrected rewrite of the student's message and the list of changes.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "corrected" => %{"type" => "string", "description" => "the full message rewritten correctly and naturally; unchanged if already correct"},
          "corrections" => %{"type" => "array", "items" => correction_item_schema()}
        },
        "required" => ["corrected", "corrections"]
      }
    }
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
  # With thinking disabled the model sometimes re-emits the whole message a second time
  # (a visible "second attempt") instead of reasoning privately. Once markers are reduced
  # to the student's own words, that doubles the word count — but every word is the
  # student's, so longest_foreign_run can't see it. Guard on gross length inflation too:
  # a faithful correction reduces back to ~the original length (insertions collapse to ""),
  # so anything past 1.5x is duplication/garble → fall back to the uncorrected text.
  @max_length_ratio 1.5
  defp uncontaminated?(annotated_text, original) do
    source_words = words(original)
    source = MapSet.new(source_words)

    reduced =
      Regex.replace(@marker, annotated_text, fn whole, inner ->
        case marker_parts(inner) do
          {before, _after, _type, _expl} -> before
          :malformed -> whole
        end
      end)

    reduced_words = words(reduced)

    longest_foreign_run(reduced_words, source) <= @max_foreign_run and
      not length_inflated?(length(reduced_words), length(source_words))
  end

  defp length_inflated?(reduced_len, original_len) when original_len > 0,
    do: reduced_len > round(original_len * @max_length_ratio)

  defp length_inflated?(_reduced_len, _original_len), do: false

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
      "corrected" => %{
        "type" => "string",
        "description" =>
          "The ENTIRE entry rewritten correctly and naturally, keeping every correct word, all punctuation, and all line breaks identical. No markup."
      },
      "corrections" => %{"type" => "array", "items" => correction_item_schema()},
      "commentary" => commentary_schema()
    }

    {properties, required} =
      with_focus_result(base, ["corrected", "corrections", "commentary"], focus_topic)

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
