defmodule DailyOutput.Flashcards.Diff do
  @moduledoc """
  Word-level diff for the study reveal screen.

  Returns a single, in-order list of operations that aligns what the user typed with the
  correct answer (from the longest common subsequence of the two word lists):

    * `%{op: :eq, text}`  — a word both got right
    * `%{op: :del, text}` — a word the user typed that is wrong/extra (struck out)
    * `%{op: :ins, text}` — the correct word the user missed (shown in green)

  A substitution renders as a `:del` immediately followed by an `:ins` — the wrong word
  struck out with the correct word in green next to it, mirroring the inline corrections
  on the proofreading pages.

  Pure and language-agnostic; the exact pass/fail decision is the caller's (an exact
  string comparison) — this only powers the highlight.
  """

  @doc "Aligned op list unifying the user's `actual` answer with the `expected` answer."
  def unified(expected, actual) when is_binary(expected) and is_binary(actual) do
    exp = tokenize(expected)
    act = tokenize(actual)
    {act_idx, exp_idx} = lcs_matches(act, exp)
    build_ops(act, exp, Enum.zip(act_idx, exp_idx))
  end

  defp tokenize(text), do: String.split(text, ~r/\s+/, trim: true)

  # Walk the matched (actual, expected) index pairs in order. Between two matches, emit
  # the user's leftover words as deletions, then the correct leftover words as insertions,
  # then the matched word as equal. Trailing leftovers are flushed at the end.
  defp build_ops(act, exp, pairs) do
    {ops, i, j} =
      Enum.reduce(pairs, {[], 0, 0}, fn {ai, bj}, {ops, i, j} ->
        ops =
          ops
          |> dels(act, i, ai)
          |> inss(exp, j, bj)
          |> add(:eq, Enum.at(act, ai))

        {ops, ai + 1, bj + 1}
      end)

    ops
    |> dels(act, i, length(act))
    |> inss(exp, j, length(exp))
    |> Enum.reverse()
  end

  defp dels(ops, act, from, to) do
    Enum.reduce(from..(to - 1)//1, ops, fn k, acc -> add(acc, :del, Enum.at(act, k)) end)
  end

  defp inss(ops, exp, from, to) do
    Enum.reduce(from..(to - 1)//1, ops, fn k, acc -> add(acc, :ins, Enum.at(exp, k)) end)
  end

  defp add(ops, op, text), do: [%{op: op, text: text} | ops]

  # Returns {matched_indices_in_a, matched_indices_in_b}, paired by position.
  defp lcs_matches(a_list, b_list) do
    a = List.to_tuple(a_list)
    b = List.to_tuple(b_list)
    n = tuple_size(a)
    m = tuple_size(b)

    dp = build_dp(a, b, n, m)
    backtrack(a, b, n, m, dp, 0, 0, [], [])
  end

  # dp[{i, j}] = LCS length of a[i..] and b[j..]; filled bottom-up so each cell's
  # dependencies ({i+1, j+1}, {i+1, j}, {i, j+1}) are already present.
  defp build_dp(a, b, n, m) do
    for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
      acc ->
        val =
          cond do
            i == n or j == m -> 0
            elem(a, i) == elem(b, j) -> 1 + Map.get(acc, {i + 1, j + 1}, 0)
            true -> max(Map.get(acc, {i + 1, j}, 0), Map.get(acc, {i, j + 1}, 0))
          end

        Map.put(acc, {i, j}, val)
    end
  end

  defp backtrack(_a, _b, n, m, _dp, i, j, acc_a, acc_b) when i == n or j == m do
    {Enum.reverse(acc_a), Enum.reverse(acc_b)}
  end

  defp backtrack(a, b, n, m, dp, i, j, acc_a, acc_b) do
    cond do
      elem(a, i) == elem(b, j) ->
        backtrack(a, b, n, m, dp, i + 1, j + 1, [i | acc_a], [j | acc_b])

      Map.get(dp, {i + 1, j}, 0) >= Map.get(dp, {i, j + 1}, 0) ->
        backtrack(a, b, n, m, dp, i + 1, j, acc_a, acc_b)

      true ->
        backtrack(a, b, n, m, dp, i, j + 1, acc_a, acc_b)
    end
  end
end
