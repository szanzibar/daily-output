defmodule DailyOutput.Flashcards.Diff do
  @moduledoc """
  Word-level diff for the study reveal screen.

  Returns a single, in-order list of operations that aligns what the user typed with the
  correct answer (from `List.myers_difference/2` on the two word lists):

    * `%{op: :eq, text}`   — a word both got right
    * `%{op: :del, text}`  — a word the user typed that is wrong/extra (struck out)
    * `%{op: :ins, text}`  — the correct word the user missed (shown in green)
    * `%{op: :case, text}` — the right word, wrong capitalization (a soft warning, never a
      hard error); `text` is the correctly-capitalized word

  A substitution renders as a `:del` immediately followed by an `:ins` — the wrong word
  struck out with the correct word in green next to it, mirroring the inline corrections
  on the proofreading pages.

  Words are aligned **case-insensitively**, so a missed capital is a `:case` warning rather
  than a struck-out error — matching the fact that capitalization never counts a card wrong.
  Quotes are stripped first (see `tokenize/1`).

  Pure and language-agnostic; the exact pass/fail decision is the caller's — this only
  powers the highlight.
  """

  @doc "Aligned op list unifying the user's `actual` answer with the `expected` answer."
  def unified(expected, actual) when is_binary(expected) and is_binary(actual) do
    exp = tokenize(expected)
    act = tokenize(actual)

    downcase(act)
    |> List.myers_difference(downcase(exp))
    |> Enum.flat_map_reduce({act, exp}, fn
      {:eq, words}, {act, exp} ->
        {a, act} = Enum.split(act, length(words))
        {e, exp} = Enum.split(exp, length(words))
        {Enum.zip_with(a, e, &match_op/2), {act, exp}}

      {:del, words}, {act, exp} ->
        {a, act} = Enum.split(act, length(words))
        {Enum.map(a, &%{op: :del, text: &1}), {act, exp}}

      {:ins, words}, {act, exp} ->
        {e, exp} = Enum.split(exp, length(words))
        {Enum.map(e, &%{op: :ins, text: &1}), {act, exp}}
    end)
    |> elem(0)
  end

  # Every Unicode quotation mark, plus the accents people type as an apostrophe.
  @quotes ~r/[\p{Quotation_Mark}ʼ´`]/u

  @doc """
  Splits text into words on whitespace, without quotes (the unit every answer comparison,
  diff, and cloze mask works in). Quotes never count, because which style you type is noise.
  """
  def tokenize(text), do: String.split(String.replace(text, @quotes, ""), ~r/\s+/, trim: true)

  @doc """
  The set of `expected` word indices the user got right in `actual`, matched
  **case-insensitively** (so a missed capital never counts as a wrong word).

  Returns a `MapSet` of indices into `tokenize(expected)`. The complement is exactly the
  words still gotten wrong — the basis for narrowing the fill-in-the-blank mask.
  """
  def correct_expected_indices(expected, actual) when is_binary(expected) and is_binary(actual) do
    # Every op but :del stands for one expected word, in order.
    unified(expected, actual)
    |> Enum.reject(&(&1.op == :del))
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{op: op}, i} -> if op == :ins, do: [], else: [i] end)
    |> MapSet.new()
  end

  # A case-insensitive match: an exact word is `:eq`; a case-only difference is a soft
  # `:case` warning carrying the correctly-capitalized word.
  defp match_op(word, word), do: %{op: :eq, text: word}
  defp match_op(_actual, expected), do: %{op: :case, text: expected}

  defp downcase(tokens), do: Enum.map(tokens, &String.downcase/1)
end
