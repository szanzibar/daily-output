defmodule DailyOutput.AI.RewriteDiff do
  @moduledoc """
  Turns a model's *rewrite* of the student's message into inline correction markers.

  Experiments (see `scripts/exp_corrections.exs`) showed that asking the model to hand-place
  `[[before||after||type||explanation]]` markers is the source of the garbled/duplicated
  corrections — it cannot express a word-order MOVE as a before/after span (the moved word ends
  up both inside and outside the span), so it garbles delimiters or gives up. So instead the
  model only does what it is reliably good at: rewrite the sentence naturally and list each
  change as `{after, type, explanation}`. WE compute the spans here, with a deterministic
  word diff of original↔rewrite, and emit the exact same marker format the rest of the app
  already reads. Malformed markers are impossible by construction.

  `annotate/3` returns the `annotated_text` string (original verbatim outside markers, all
  whitespace and line breaks preserved). Empty result falls back to the original.
  """

  # A change region between two aligned anchors: the original words that were deleted/replaced
  # (`before`, verbatim slice of the original) and the words that replace them (`after`).
  # Byte offsets into the original so we can rebuild it without touching a single other char.

  @doc """
  Builds `annotated_text` for `original` given the model's `corrected` rewrite and its
  `corrections` list (`[%{"after" => ..., "type" => ..., "explanation" => ...}]`, `"before"`
  optional). Spans come from the diff; type/explanation are matched to each span from the list.
  """
  def annotate(original, corrected, corrections)
      when is_binary(original) and is_binary(corrected) do
    regions = regions(original, corrected)
    metas = match(regions, List.wrap(corrections))

    {out, cursor} =
      regions
      |> Enum.zip(metas)
      |> Enum.reduce({"", 0}, fn {r, meta}, {out, cursor} ->
        verbatim = binary_part(original, cursor, r.start - cursor)
        seg = marker(r.before, r.after, meta)
        # A pure insertion adds a word between two existing ones; give it a trailing space so
        # the corrected reading isn't glued ("bin ich", not "binich"). Deletes/replaces reuse
        # the original's own spacing, so they stay byte-exact.
        seg = if r.before == "", do: seg <> " ", else: seg
        {out <> verbatim <> seg, r.stop}
      end)

    result = out <> binary_part(original, cursor, byte_size(original) - cursor)
    if String.trim(result) == "", do: original, else: result
  end

  def annotate(original, _corrected, _corrections), do: original

  @doc """
  The ordered list of `%{"before" => ..., "after" => ...}` changes between `original` and
  `corrected` — the diff regions themselves, with no explanations. This is what a two-call flow
  hands to the "explain each change" step: the diff (not the model) decides the change list, so
  every change gets labelled exactly once, in order.
  """
  def changes(original, corrected) when is_binary(original) and is_binary(corrected) do
    original
    |> regions(corrected)
    |> Enum.map(&%{"before" => &1.before, "after" => &1.after})
  end

  def changes(_original, _corrected), do: []

  defp marker(before, after_, %{"type" => type, "explanation" => expl}) do
    "[[#{before}||#{after_}||#{type}||#{String.trim(expl)}]]"
  end

  # ── Region diff ─────────────────────────────────────────────────────────────
  # Word tokens of the original carry their byte offset so the rebuild preserves every
  # original space/newline outside a region. The rewrite is compared by word text only.
  defp regions(original, corrected) do
    orig = tokens_with_offsets(original)
    corr = Enum.map(tokens_with_offsets(corrected), & &1.text)
    a = orig |> Enum.map(& &1.text) |> List.to_tuple()
    b = List.to_tuple(corr)
    {ai, bi} = lcs(a, b)

    build_regions(orig, corr, Enum.zip(ai, bi), byte_size(original))
  end

  # Walk matched (orig_idx, corr_idx) pairs; between two anchors, the original words in the gap
  # are the deletion and the rewrite words in the gap are the insertion → one region.
  defp build_regions(orig, corr, pairs, orig_bytes) do
    {regions, oi, ci} =
      Enum.reduce(pairs, {[], 0, 0}, fn {mo, mc}, {regions, oi, ci} ->
        regions = add_region(regions, orig, corr, oi, mo, ci, mc, orig_bytes)
        {regions, mo + 1, mc + 1}
      end)

    add_region(regions, orig, corr, oi, length(orig), ci, length(corr), orig_bytes)
    |> Enum.reverse()
  end

  # Region for deleted original words [oi, mo) and inserted rewrite words [ci, mc).
  defp add_region(regions, _orig, _corr, oi, mo, ci, mc, _bytes) when oi == mo and ci == mc,
    do: regions

  defp add_region(regions, orig, corr, oi, mo, ci, mc, orig_bytes) do
    del = Enum.slice(orig, oi, mo - oi)
    ins = Enum.slice(corr, ci, mc - ci)
    before = del |> Enum.map(& &1.text) |> Enum.join(" ")
    after_ = Enum.join(ins, " ")

    {start, stop} =
      case del do
        [] ->
          # pure insertion: anchor at the start of the next original word (or end of text)
          point = if mo < length(orig), do: Enum.at(orig, mo).start, else: orig_bytes
          {point, point}

        _ ->
          first = List.first(del)
          last = List.last(del)
          {first.start, last.start + last.len}
      end

    [%{before: before, after: after_, start: start, stop: stop} | regions]
  end

  defp tokens_with_offsets(text) do
    ~r/\S+/u
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{s, l}] -> %{start: s, len: l, text: binary_part(text, s, l)} end)
  end

  # ── Metadata matching ─────────────────────────────────────────────────────
  # Attach each region's {type, explanation} from the model's change list by WORD OVERLAP:
  # the correction sharing the most words with the region's before∪after wins. No position/
  # order fallback — on a long entry the model's list rarely lines up 1:1 with the diff's
  # regions, and grabbing "the next one" mislabels a span (a wrong explanation is worse than
  # none). Overlap also makes it order-independent, lets one correction cover a split span, and
  # matches a move's strike-half ("sich" deleted here) to its insertion correction ("sich"). A
  # region no correction overlaps stays unexplained rather than mislabelled.
  defp match(regions, corrections) do
    Enum.map(regions, fn r ->
      target = wordset(r.before, r.after)

      corrections
      |> Enum.map(fn c -> {overlap(target, wordset(c["before"], c["after"])), c} end)
      |> Enum.filter(fn {n, _c} -> n > 0 end)
      |> Enum.max_by(fn {n, _c} -> n end, fn -> nil end)
      |> case do
        {_n, c} -> meta(c)
        nil -> %{"type" => "other", "explanation" => ""}
      end
    end)
  end

  defp meta(c) do
    %{
      "type" => to_string(c["type"] || "other"),
      "explanation" => to_string(c["explanation"] || "")
    }
  end

  defp wordset(a, b), do: MapSet.new(words(a) ++ words(b))
  defp words(nil), do: []
  defp words(s), do: s |> to_string() |> String.downcase() |> String.split(~r/\s+/, trim: true)
  defp overlap(a, b), do: MapSet.size(MapSet.intersection(a, b))

  # ── Longest common subsequence of two word tuples (case-sensitive) ──────────
  # Returns {matched_indices_in_a, matched_indices_in_b}. Same shape as Flashcards.Diff but
  # case-sensitive — German capitalization is a real correction, not a soft warning here.
  defp lcs(a, b) do
    n = tuple_size(a)
    m = tuple_size(b)

    dp =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        acc ->
          v =
            cond do
              i == n or j == m -> 0
              elem(a, i) == elem(b, j) -> 1 + Map.get(acc, {i + 1, j + 1}, 0)
              true -> max(Map.get(acc, {i + 1, j}, 0), Map.get(acc, {i, j + 1}, 0))
            end

          Map.put(acc, {i, j}, v)
      end

    back(a, b, n, m, dp, 0, 0, [], [])
  end

  defp back(_a, _b, n, m, _dp, i, j, xa, xb) when i == n or j == m,
    do: {Enum.reverse(xa), Enum.reverse(xb)}

  defp back(a, b, n, m, dp, i, j, xa, xb) do
    cond do
      elem(a, i) == elem(b, j) ->
        back(a, b, n, m, dp, i + 1, j + 1, [i | xa], [j | xb])

      Map.get(dp, {i + 1, j}, 0) >= Map.get(dp, {i, j + 1}, 0) ->
        back(a, b, n, m, dp, i + 1, j, xa, xb)

      true ->
        back(a, b, n, m, dp, i, j + 1, xa, xb)
    end
  end
end
