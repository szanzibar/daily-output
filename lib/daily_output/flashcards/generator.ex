defmodule DailyOutput.Flashcards.Generator do
  @moduledoc """
  Turns a corrected piece of writing into spaced-repetition flashcards.

  For each sentence the student struggled with, the model produces the **natural,
  idiomatic** way a native speaker would say what the student was trying to say — not a
  literal patch of their phrasing — and a matching translation. Naturalness is the goal;
  the corrected text and mistakes list are context, and it's fine if the natural phrasing
  sidesteps the exact construction that was wrong. Output is calibrated to the learner's
  CEFR level and biased toward one canonical phrasing (the answer is typed back exactly).

  Returns one card per substantive mistake: `target_text` (the sentence to type) and
  `native_text` (its translation).

  Fully language-agnostic — `target`/`native`/`level` come from settings and conventions
  are resolved via `AI.LanguageProfile`. Uses tool_use for structured output, mirroring
  `AI.Proofreader`.
  """

  require Logger

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc """
  Builds flashcards from `corrected_text` and the `mistakes` that were corrected.

  `mistakes` is a list of `%{original, corrected, category, explanation}`.
  Returns `{:ok, [%{"target_text" => ..., "native_text" => ...}]}` or `{:error, reason}`.
  """
  def generate(corrected_text, mistakes, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
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
    The learner is a #{native_name} speaker learning #{profile.prompt_name}.

    You are given the corrected #{profile.language_name} text (a minimal grammar fix of what the
    student wrote) plus the list of mistakes that were corrected. Even after the grammar fix, the
    student's own phrasing is often stiff or unnatural.

    Your goal: for each sentence the student struggled with, teach them the NATURAL, IDIOMATIC way a
    native speaker would express that same idea — that is what they should practice — and translate
    THAT sentence.#{conventions_block}

    Rules:
    - Make one card per sentence that contained a substantive mistake. Skip sentences that were
      already correct, and skip corrections that were only capitalization (letter casing).
    - "target_text" = the most natural, idiomatic #{profile.language_name} a native speaker would
      actually use to say what the student was trying to say. Do NOT merely patch the student's
      wording — rephrase it into natural #{profile.language_name}, preserving the intended meaning.
    - Naturalness comes FIRST. It is fine — expected, even — if the natural phrasing avoids the exact
      construction the student got wrong (e.g. a case or preposition). Learning to say it the native
      way is the whole point; the mistakes list is only context for what they were attempting.
    - "native_text" = a natural #{native_name} translation that matches target_text as closely as
      reads naturally. It need NOT match what the student originally wrote in #{native_name}.
    - Calibrate to CEFR level #{level}: natural but within reach — avoid rare idioms, slang, or
      vocabulary a #{level} learner wouldn't know.
    - Prefer ONE clear, canonical phrasing. The student must type target_text back EXACTLY, so avoid
      optional flavouring particles or word-order variants that have many equally valid forms.
    - Split a long/compound sentence into separate single-idea sentences — one card each.
    - Keep sentences short and practical. Do not include quotation marks around the sentences.

    Use the provide_flashcards tool to return your response.
    """

    user_content = """
    Corrected #{profile.language_name} text:
    #{corrected_text}

    What the student got wrong (context only — you need not preserve these constructions):
    #{format_mistakes(mistakes)}
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: user_content}],
             tools: [flashcards_tool()],
             tool_choice: %{type: "tool", name: "provide_flashcards"},
             purpose: "flashcards",
             max_tokens: 1536
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => %{"cards" => cards}} when is_list(cards) ->
              {:ok, normalize_cards(cards)}

            %{"input" => input} when is_map(input) ->
              {:ok, []}

            _ ->
              Logger.error("Generator: no tool_use block in response: #{inspect(content)}")
              {:error, :no_tool_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
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
    level = Keyword.get(opts, :language_level, "B2")
    profile = LanguageProfile.resolve(target)
    native_name = LanguageProfile.resolve(native).language_name

    conventions_block =
      if profile.conventions == [],
        do: "",
        else:
          "\n\nConventions for #{profile.prompt_name} (target_text MUST follow these):\n#{LanguageProfile.conventions_block(profile)}\n"

    system = """
    You are improving ONE #{profile.language_name} flashcard for a #{native_name} speaker
    (CEFR level #{level}). The learner can't tell, from the #{native_name} prompt alone, what
    #{profile.language_name} sentence is wanted — the pair is too ambiguous or the translation
    is too loose.#{conventions_block}

    Produce a single, clearer card with the SAME meaning and topic:
    - "target_text" = a natural, correct #{profile.language_name} sentence (level #{level}, one
      clear canonical phrasing).
    - "native_text" = a #{native_name} translation that points clearly and unambiguously to that
      exact #{profile.language_name} sentence. It is fine to make the #{native_name} a little more
      explicit or literal so the learner can derive the target, as long as it stays grammatical
      and natural enough to read.

    Return exactly one card via the provide_flashcards tool.
    """

    user_content = """
    Current card:
    #{profile.language_name}: #{card.target_text}
    #{native_name}: #{card.native_text}
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: user_content}],
             tools: [flashcards_tool()],
             tool_choice: %{type: "tool", name: "provide_flashcards"},
             purpose: "flashcards",
             max_tokens: 512
           ) do
        {:ok, %{"content" => content}} ->
          case Enum.find(content, &(&1["type"] == "tool_use")) do
            %{"input" => %{"cards" => [_ | _] = cards}} ->
              case normalize_cards(cards) do
                [pair | _] -> {:ok, pair}
                [] -> {:error, :empty}
              end

            _ ->
              {:error, :no_tool_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp format_mistakes([]), do: "(none)"

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

  @doc false
  def flashcards_tool do
    %{
      name: "provide_flashcards",
      description: "Provide the flashcards built from the learner's corrected writing",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "cards" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "target_text" => %{
                  "type" => "string",
                  "description" => "The fully correct target-language sentence to type"
                },
                "native_text" => %{
                  "type" => "string",
                  "description" => "A natural native-language translation of the sentence"
                }
              },
              "required" => ["target_text", "native_text"]
            }
          }
        },
        "required" => ["cards"]
      }
    }
  end
end
