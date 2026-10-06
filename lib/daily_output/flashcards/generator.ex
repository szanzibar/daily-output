defmodule DailyOutput.Flashcards.Generator do
  @moduledoc """
  Turns a corrected piece of writing into spaced-repetition flashcards.

  For each sentence the student struggled with, the model produces the **natural,
  idiomatic** way a native speaker would say what the student was trying to say — not a
  literal patch of their phrasing — and a translation that follows its structure, so the
  prompt shows how the target sentence is built. The target's naturalness comes first; the
  corrected text and mistakes list are context, and it's fine if the natural phrasing
  sidesteps the exact construction that was wrong. Output is calibrated to the learner's
  CEFR level and biased toward one canonical phrasing (the answer is typed back exactly).

  Returns one card per substantive mistake: `target_text` (the sentence to type) and
  `native_text` (its translation).

  Fully language-agnostic — `target`/`native`/`level` come from settings and conventions
  are resolved via `AI.LanguageProfile`. Uses structured output, like `AI.Proofreader`.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc """
  Builds flashcards from `corrected_text` (the corrected sentences that had a mistake, one
  per line) and the `mistakes` that were corrected.

  `mistakes` is a list of `%{original, corrected, category, explanation}`.
  Returns `{:ok, [%{"target_text" => ..., "native_text" => ...}]}` or `{:error, reason}`.
  """
  def generate(corrected_text, mistakes, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.fetch!(opts, :language_level)
    profile = LanguageProfile.resolve(target)
    native_name = LanguageProfile.resolve(native).language_name

    conventions_block =
      if profile.conventions == [] do
        ""
      else
        "\n\nConventions for #{profile.prompt_name} (target_text MUST follow these):\n#{LanguageProfile.conventions_block(profile)}\n"
      end

    system = """
    You build spaced-repetition flashcards from a language learner's writing that was just corrected.
    The learner is a native #{native_name} speaker learning #{profile.prompt_name}.

    You are given the #{profile.language_name} sentences the student got wrong, one per line,
    already corrected (a minimal fix of what they wrote), plus the list of mistakes. Even after
    the fix, the student's own phrasing is often stiff or unnatural.

    Your goal: for each sentence the student struggled with, teach them the NATURAL, IDIOMATIC way a
    native speaker would express that same idea — that is what they should practice — and translate
    THAT sentence.#{conventions_block}

    Rules:
    - ONE sentence per card. Each "target_text" is a SINGLE sentence — one idea, one main clause,
      ending in exactly one period or question mark. Never put two sentences or a run-on onto one card.
    - Make exactly one card per line. If a line is long or joins several ideas, build the card from
      the part with the mistake. Never make a card for a part the student already got right.
    - "target_text" = the most natural, idiomatic #{profile.language_name} a native speaker would
      actually use to say what the student was trying to say. Do NOT merely patch the student's
      wording — rephrase it into natural #{profile.language_name}, preserving the intended meaning.
    - Naturalness comes FIRST. It is fine — expected, even — if the natural phrasing avoids the exact
      construction the student got wrong (e.g. a case or preposition). Learning to say it the native
      way is the whole point; the mistakes list is only context for what they were attempting.
    - "native_text" = a #{native_name} translation that mirrors target_text's structure, so the
      student sees how the #{profile.language_name} is built. Keep its word order: if target_text
      starts with the object, an adverb, or a clause, so does the translation. Keep its
      constructions and its subject, and translate phrase by phrase instead of paraphrasing.
      Slightly awkward #{native_name} is fine; word salad is not. It need NOT match what the
      student originally wrote in #{native_name}.
    - Calibrate to CEFR level #{level}: natural but within reach — avoid rare idioms, slang, or
      vocabulary a #{level} learner wouldn't know.
    - Prefer ONE clear, canonical phrasing. The student must type target_text back EXACTLY, so avoid
      optional flavouring particles or word-order variants that have many equally valid forms.
    - Keep sentences short and practical. Do not include quotation marks around the sentences.
    """

    user_content = """
    Sentences with a mistake, corrected:
    #{corrected_text}

    What the student got wrong (context only — you need not preserve these constructions):
    #{format_mistakes(mistakes)}
    """

    with {:ok, %{"cards" => cards}} <-
           AI.chat(
             [
               system: system,
               messages: [%{role: "user", content: user_content}],
               schema: flashcards_schema(),
               purpose: "flashcards",
               # max_tokens is a ceiling, not a billed cost. A whole conversation's worth of
               # cards can be long, and 1536 once truncated the reply (zero cards).
               max_tokens: 4096
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      {:ok, normalize_cards(cards)}
    end
  end

  @doc """
  Suggests a clearer replacement pair for an existing card the learner can't answer from
  the prompt alone. Keeps the meaning, but makes the native prompt point unambiguously to
  the target sentence. Returns `{:ok, %{"target_text", "native_text"}}` or `{:error, _}`.
  """
  def improve(card, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.fetch!(opts, :language_level)
    profile = LanguageProfile.resolve(target)
    native_name = LanguageProfile.resolve(native).language_name

    conventions_block =
      if profile.conventions == [],
        do: "",
        else:
          "\n\nConventions for #{profile.prompt_name} (target_text MUST follow these):\n#{LanguageProfile.conventions_block(profile)}\n"

    system = """
    You are improving ONE #{profile.language_name} flashcard for a native #{native_name} speaker
    (CEFR level #{level}). The learner can't tell, from the #{native_name} prompt alone, what
    #{profile.language_name} sentence is wanted — the pair is too ambiguous or the translation
    is too loose.#{conventions_block}

    Produce a single, clearer card with the SAME meaning and topic:
    - "target_text" = a natural, correct #{profile.language_name} sentence (level #{level}, one
      clear canonical phrasing).
    - "native_text" = a #{native_name} translation that points clearly and unambiguously to that
      exact #{profile.language_name} sentence and mirrors its structure. Keep its word order: if
      it starts with the object, an adverb, or a clause, so does the translation. Keep its
      constructions and its subject, and translate phrase by phrase instead of paraphrasing.
      Slightly awkward or literal #{native_name} is fine; word salad is not.

    Return exactly one card.
    """

    user_content = """
    Current card:
    #{profile.language_name}: #{card.target_text}
    #{native_name}: #{card.native_text}
    """

    with {:ok, %{"cards" => cards}} <-
           AI.chat(
             system: system,
             messages: [%{role: "user", content: user_content}],
             schema: flashcards_schema(),
             purpose: "flashcards",
             max_tokens: 2048
           ) do
      case normalize_cards(cards) do
        [pair | _] -> {:ok, pair}
        [] -> {:error, :empty}
      end
    end
  end

  defp format_mistakes(mistakes) do
    Enum.map_join(mistakes, "\n", fn m ->
      orig = if m.original == "", do: "(missing)", else: m.original
      corrected = if m.corrected == "", do: "(removed)", else: m.corrected
      "- #{orig} → #{corrected} (#{m.category}: #{m.explanation})"
    end)
  end

  defp normalize_cards(cards) do
    cards
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn card ->
      %{
        "target_text" => card["target_text"] |> to_string() |> String.trim(),
        "native_text" => card["native_text"] |> to_string() |> String.trim()
      }
    end)
    |> Enum.reject(&(&1["target_text"] == "" or &1["native_text"] == ""))
  end

  defp flashcards_schema do
    %{
      "type" => "object",
      "properties" => %{
        "cards" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "target_text" => %{
                "type" => "string",
                "description" =>
                  "A single fully correct target-language sentence to type — exactly one sentence, never two and never the whole message"
              },
              "native_text" => %{
                "type" => "string",
                "description" =>
                  "A native-language translation that mirrors the target sentence's word order and structure"
              }
            },
            "required" => ["target_text", "native_text"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["cards"],
      "additionalProperties" => false
    }
  end
end
