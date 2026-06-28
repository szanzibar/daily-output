defmodule DailyOutput.Flashcards.Cloze do
  @moduledoc """
  Progressive fill-in-the-blank ("cloze") logic for the study session.

  A card carries a `blank_indices` mask — the word indices (into the whitespace-tokenized
  `target_text`) that are still **hidden**. The rest of the answer is shown to the learner.

    * `nil` → the whole answer is hidden: a brand-new card you type in full.
    * `[i, j, …]` → only those words are hidden; consecutive hidden words collapse into a
      single blank, so a missed phrase is one input, not one-per-word.

  The mask only ever gets *easier*: a miss narrows it to the exact words still gotten wrong
  (revealing the ones you now got right), and a pass holds it steady so the card comes back
  at the same difficulty. Editing the answer text resets it (see `Card.edit_changeset/2`).

  Pure and language-agnostic; comparison is case-insensitive (a missed capital is flagged
  as a gentle warning, never marked wrong).
  """

  alias DailyOutput.Flashcards.Diff

  @doc """
  Ordered render segments for `target_text` under a (non-nil) `blank_indices` mask.

  Consecutive hidden words are grouped into one blank keyed by the first word's index:

    * `{:shown, "Ich ging"}` — revealed word(s), printed as-is
    * `{:blank, 1, "nach Hause."}` — a hidden span; the learner types it, `1` is its key
  """
  def segments(target_text, blank_indices) when is_list(blank_indices) do
    hidden = MapSet.new(blank_indices)

    target_text
    |> Diff.tokenize()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {_word, i} -> MapSet.member?(hidden, i) end)
    |> Enum.map(fn [{_word, first} | _] = chunk ->
      text = chunk |> Enum.map(&elem(&1, 0)) |> Enum.join(" ")
      if MapSet.member?(hidden, first), do: {:blank, first, text}, else: {:shown, text}
    end)
  end

  @doc """
  Evaluates an `answer` against `card` and returns a verdict the study view can act on.

  `answer` is the raw typed string for a full-answer card (`blank_indices == nil`), or a
  `%{index => typed}` map of the filled blanks for a cloze card. The verdict:

    * `:result` — `:pass` / `:fail` (case-insensitive match of every required word)
    * `:exact?` — whether it matched with capitalization too
    * `:case_diffs` — `[%{typed, expected}]` for words right except for case (the warning)
    * `:new_blank_indices` — the mask to persist: narrowed to the still-wrong words on a
      miss, held unchanged on a pass
    * `:diff` — the word-level reveal diff (only on a miss; `nil` otherwise)
  """
  def evaluate(target_text, blank_indices, answer) do
    expected = Diff.tokenize(target_text)
    attempt = attempt_tokens(target_text, blank_indices, answer)
    attempt_text = Enum.join(attempt, " ")

    exact? = attempt == expected
    pass? = downcase(attempt) == downcase(expected)

    %{
      result: if(pass?, do: :pass, else: :fail),
      exact?: exact?,
      case_diffs: if(pass? and not exact?, do: case_diffs(expected, attempt), else: []),
      new_blank_indices: new_mask(target_text, blank_indices, attempt_text, pass?),
      diff: if(pass?, do: nil, else: Diff.unified(target_text, attempt_text))
    }
  end

  # The learner's full attempt as a flat word list: shown spans contribute the real words,
  # blanks contribute whatever was typed (which may be a different number of words).
  defp attempt_tokens(_target_text, nil, answer) when is_binary(answer), do: Diff.tokenize(answer)

  defp attempt_tokens(target_text, blank_indices, answer) when is_map(answer) do
    target_text
    |> segments(blank_indices)
    |> Enum.flat_map(fn
      {:shown, text} -> Diff.tokenize(text)
      {:blank, key, _expected} -> Diff.tokenize(Map.get(answer, key, ""))
    end)
  end

  # On a pass the mask is unchanged. On a miss it narrows to the words still gotten wrong
  # (case-insensitively); if that's the whole answer there's nothing to reveal, so fall
  # back to a full-answer prompt (nil). An empty wrong-set on a miss (e.g. extra/reordered
  # words) leaves the difficulty untouched rather than blanking nothing.
  defp new_mask(_target_text, blank_indices, _attempt_text, true), do: blank_indices

  defp new_mask(target_text, blank_indices, attempt_text, false) do
    all = MapSet.new(0..(length(Diff.tokenize(target_text)) - 1))
    wrong = MapSet.difference(all, Diff.correct_expected_indices(target_text, attempt_text))

    cond do
      MapSet.size(wrong) == 0 -> blank_indices
      MapSet.equal?(wrong, all) -> nil
      true -> Enum.sort(wrong)
    end
  end

  # Pass-only: attempt and expected are the same words modulo case, so a positional zip
  # surfaces exactly the words typed with the wrong capitalization.
  defp case_diffs(expected, attempt) do
    expected
    |> Enum.zip(attempt)
    |> Enum.reject(fn {e, a} -> e == a end)
    |> Enum.map(fn {e, a} -> %{expected: e, typed: a} end)
  end

  defp downcase(tokens), do: Enum.map(tokens, &String.downcase/1)
end
