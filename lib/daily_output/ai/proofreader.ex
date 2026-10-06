defmodule DailyOutput.AI.Proofreader do
  @moduledoc """
  AI proofreading. The journal's `proofread/2` and the chat's `proofread_message/2` ask the
  model for a clean rewrite plus a list of `{before, after, type, explanation}` changes.
  `AI.RewriteDiff` builds the inline markers from a word diff of the two, so a garbled marker
  can't happen. The feedback is `%{"annotated_text" => ...}`, read through `Markers`.

  The wrap-up calls, `proofread/2` and `assess_conversation/2`, also grade today's focus
  (`focus_result`) and write a one-sentence `summary` the next session picks up from.
  """

  require Logger

  alias DailyOutput.{AI, Markers}
  alias DailyOutput.AI.{LanguageProfile, RewriteDiff}

  # Error categories used to tag per-message corrections. They let us measure, at the end
  # of a conversation, which kinds of mistakes the student repeated vs. stopped making.
  @categories ~w(gender case verb word-order agreement preposition spelling vocabulary punctuation other)

  @doc "The categories the model tags each correction with."
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

    Watch especially for set phrases copied word for word from #{native}. They're grammatical, so they slip through. If a phrase mirrors #{native} and the usual native phrase is a different one, it's a mistake, even if some natives say it too: replace the whole phrase with the usual one. Fixing only its grammar is not enough.

    Be thorough but balanced, and tailor to a CEFR #{level} learner: mark the errors and unnatural phrasing that will help them progress — common mistakes included — but don't nitpick, don't flag constructions clearly above their level, and leave anything already correct and natural untouched. Never invent errors.\
    """
  end

  defp context_block(""), do: ""
  defp context_block(context), do: "\n\nAdditional context about the student:\n#{context}\n"

  defp language_conventions(%{conventions: []}), do: ""

  defp language_conventions(profile),
    do:
      "\n\nLanguage-specific conventions for #{profile.prompt_name}:\n#{LanguageProfile.conventions_block(profile)}\n"

  # The wrap-up asks shared by the journal proofread and the conversation review. `scope` is
  # "entry" or "conversation".
  defp review_instructions(%{"title" => title, "body" => body}, scope, native, feedback_lang) do
    """
    "summary": one short sentence (at most 25 words) in #{native}, to the student ("you …"), on what this #{scope} was about, with a concrete detail or two (people, places, plans), so the next session can pick up where they left off.

    "focus_result": today's focus was «#{title}» (#{body}). Grade what the student wrote, not the corrected version. Judge by meaning, not exact keywords:
    - used: did they attempt it anywhere in the #{scope}? Any inflection or variant counts.
    - correct: every attempt was right as written. If any correction changes the focus itself, it's false; corrections elsewhere in a sentence don't count. Always false when not used.
    - comment: one short sentence in #{feedback_lang} that matches the two booleans.
    """
  end

  @doc """
  Proofreads a journal entry and grades today's `:focus` (the banner map). Returns
  `{:ok, %{"annotated_text", "summary", "focus_result"}}` or `{:error, reason}`.
  """
  def proofread(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.fetch!(opts, :language_level)
    profile = LanguageProfile.resolve(target)
    feedback_lang = LanguageProfile.feedback_language(level, target, opts[:native_language])

    system = """
    You are a #{profile.prompt_name} teacher proofreading a journal entry written by a native #{native} speaker at CEFR level #{level}.#{language_conventions(profile)}

    #{correction_goal(profile, native, level)}

    Respond with:
    1. "corrected" — the ENTIRE entry rewritten correctly and naturally. Change ONLY what needs fixing; keep every correct word, all punctuation, and all line breaks (including the blank lines between paragraphs) identical. Do NOT add any markup.
    2. "corrections" — one entry per change, in the order the changes appear, each with "before" (the student's original words, empty if you inserted), "after" (your correction, empty if you deleted), "type" (one of {#{Enum.join(@categories, ", ")}}), and "explanation" (5-10 words on what was wrong). Every change in "corrected" has exactly one entry here.
    3. #{review_instructions(Keyword.fetch!(opts, :focus), "entry", native, feedback_lang)}
    Write ALL explanation text in #{feedback_lang}.#{context_block(Keyword.get(opts, :about_you, ""))}
    """

    with {:ok, input} <-
           AI.chat(
             [
               system: system,
               messages: [
                 %{role: "user", content: "Please proofread this journal entry:\n\n#{text}"}
               ],
               schema: journal_schema(),
               purpose: "proofread",
               # A ceiling, not a cost. A full-entry rewrite, its change list, and the reasoning
               # all count; Luna used 1976 on a 90-word entry.
               max_tokens: 8192
             ] ++ Keyword.take(opts, [:model, :effort])
           ),
         {:ok, corrections} <- rewrite_feedback(input, text) do
      {:ok, Map.merge(corrections, normalize_review(input))}
    end
  end

  @doc """
  Wraps up a finished conversation. Each message was already corrected as it was sent, so
  this only writes the `summary` and grades today's `:focus`. `messages` is the transcript as
  `%{role, body}` maps, with `feedback` on the student's.

  Returns `{:ok, %{"summary", "focus_result"}}` or `{:error, reason}`.
  """
  def assess_conversation(messages, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.fetch!(opts, :language_level)
    profile = LanguageProfile.resolve(target)
    feedback_lang = LanguageProfile.feedback_language(level, target, opts[:native_language])

    system = """
    You review a finished casual chat in #{profile.prompt_name} between a native #{native} speaker (CEFR level #{level}) and a partner. The student's messages were already corrected; their fixes are listed under each one. Don't correct anything.

    Respond with:
    #{review_instructions(Keyword.fetch!(opts, :focus), "conversation", native, feedback_lang)}
    """

    with {:ok, input} <-
           AI.chat(
             [
               system: system,
               messages: [%{role: "user", content: assessment_transcript(messages)}],
               schema: review_schema(),
               purpose: "assessment",
               max_tokens: 1024
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      {:ok, normalize_review(input)}
    end
  end

  # The transcript with each student message's fixes as before → after, so the focus grade
  # sees what went wrong without the explanations.
  defp assessment_transcript(messages) do
    Enum.map_join(messages, "\n", fn
      %{role: "user"} = msg ->
        fixes =
          msg.feedback["annotated_text"]
          |> Markers.parse()
          |> Enum.map_join("; ", &"#{&1.original} → #{&1.corrected}")

        if fixes == "",
          do: "Student: #{msg.body}",
          else: "Student: #{msg.body}\n  (fixed: #{fixes})"

      msg ->
        "Partner: #{msg.body}"
    end)
  end

  @doc """
  Proofreads a single conversation message, right after the student sends it.

  Unlike `proofread/2` (a journal entry) this is calibrated for casual chat: casual register
  stays, but word-for-word translations get fixed. Each correction is tagged with a
  `category` so we can later measure improvement within the conversation. Prior turns are
  passed via `:context_messages` (a list of `%{role, body}`) so the model understands what
  the student is replying to, but it corrects ONLY the latest message.

  Returns `{:ok, %{"annotated_text" => ...}}` or `{:error, reason}`.
  """
  def proofread_message(text, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.fetch!(opts, :language_level)
    context = Keyword.get(opts, :about_you, "")
    history = Keyword.get(opts, :context_messages, [])
    profile = LanguageProfile.resolve(target)

    feedback_lang = LanguageProfile.feedback_language(level, target, opts[:native_language])
    context_block = context_block(context)
    language_conventions_block = language_conventions(profile)

    system = """
    You are a #{profile.prompt_name} teacher correcting one message a native #{native} speaker (CEFR level #{level}) just sent in a casual chat.#{language_conventions_block}

    #{correction_goal(profile, native, level)}

    This is a casual text chat, so casual register is correct: dropped subjects, clipped or contracted words, and colloquial forms that natives type in chat are NOT mistakes. Leave them exactly as they are. A word-for-word translation from #{native} is different: it's a mistake, however casual the chat.

    Write ALL explanation text in #{feedback_lang}.
    #{context_block}
    Respond with:
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

    with {:ok, input} <-
           AI.chat(
             [
               system: system,
               messages: [%{role: "user", content: user_content}],
               schema: message_schema(),
               purpose: "proofread_message",
               # A ceiling, not a cost. Reasoning counts against it, and Luna once used 613.
               max_tokens: 2048
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      rewrite_feedback(input, text)
    end
  end

  # An empty rewrite is a parse miss.
  @doc false
  def rewrite_feedback(%{"corrected" => corrected} = input, original)
      when is_binary(corrected) and corrected != "" do
    annotated = RewriteDiff.annotate(original, corrected, input["corrections"])
    {:ok, %{"annotated_text" => String.trim(annotated)}}
  end

  def rewrite_feedback(input, _original) do
    Logger.warning("proofread: empty rewrite in #{inspect(input)}")
    {:error, :unparsed}
  end

  # One change in a rewrite: the original span, its replacement, and why. Shared by the chat
  # and journal schemas so the two never drift. RewriteDiff matches these back to the diff of
  # original↔rewrite to build the inline markers.
  defp correction_item_schema do
    %{
      "type" => "object",
      "properties" => %{
        "after" => %{
          "type" => "string",
          "description" => "the corrected words as they appear in the rewrite (empty to delete)"
        },
        "before" => %{
          "type" => "string",
          "description" => "the student's original words that changed (empty to insert)"
        },
        "type" => %{"type" => "string", "enum" => @categories},
        "explanation" => %{"type" => "string", "description" => "5-10 words on what was wrong"}
      },
      "required" => ["after", "before", "type", "explanation"],
      "additionalProperties" => false
    }
  end

  defp message_schema do
    %{
      "type" => "object",
      "properties" => %{
        "corrected" => %{
          "type" => "string",
          "description" =>
            "the full message rewritten correctly and naturally; unchanged if already correct"
        },
        "corrections" => %{"type" => "array", "items" => correction_item_schema()}
      },
      "required" => ["corrected", "corrections"],
      "additionalProperties" => false
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

  @doc false
  def journal_schema do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(review_schema()["properties"], %{
          "corrected" => %{
            "type" => "string",
            "description" =>
              "The ENTIRE entry rewritten correctly and naturally, keeping every correct word, all punctuation, and all line breaks identical. No markup."
          },
          "corrections" => %{"type" => "array", "items" => correction_item_schema()}
        }),
      "required" => ["corrected", "corrections", "summary", "focus_result"],
      "additionalProperties" => false
    }
  end

  @doc false
  def review_schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string", "description" => "One sentence: where they left off"},
        "focus_result" => %{
          "type" => "object",
          "properties" => %{
            "used" => %{"type" => "boolean"},
            "correct" => %{"type" => "boolean", "description" => "Must be false when used=false"},
            "comment" => %{"type" => "string"}
          },
          "required" => ["used", "correct", "comment"],
          "additionalProperties" => false
        }
      },
      "required" => ["summary", "focus_result"],
      "additionalProperties" => false
    }
  end

  @doc false
  def normalize_review(%{
        "summary" => summary,
        "focus_result" => %{"used" => used, "correct" => correct, "comment" => comment}
      }) do
    %{
      "summary" => String.trim(summary),
      "focus_result" => %{
        "used" => used,
        "correct" => used and correct,
        "comment" => String.trim(comment)
      }
    }
  end
end
