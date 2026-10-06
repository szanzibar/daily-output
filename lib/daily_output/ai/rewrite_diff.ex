defmodule DailyOutput.AI.RewriteDiff do
  @moduledoc """
  Turns a model's *rewrite* of the student's message into inline correction markers.

  Experiments showed that asking the model to hand-place
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
  `corrections` list (`[%{"before" => ..., "after" => ..., "type" => ..., "explanation" => ...}]`).
  Spans come from the diff; type/explanation are matched to each span from the list.
  """
  def annotate(original, corrected, corrections)
      when is_binary(original) and is_binary(corrected) do
    orig = tokens_with_offsets(original)
    corr = Enum.map(tokens_with_offsets(corrected), & &1.text)
    regions = regions(orig, corr, byte_size(original))
    metas = match(regions, orig, corr, List.wrap(corrections))

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

  defp marker(before, after_, %{"type" => type, "explanation" => expl}) do
    "[[#{before}||#{after_}||#{type}||#{String.trim(expl)}]]"
  end

  # ── Region diff ─────────────────────────────────────────────────────────────
  # Word tokens of the original carry their byte offset so the rebuild preserves every
  # original space/newline outside a region. The rewrite is compared by word text only.
  defp regions(orig, corr, orig_bytes) do
    a = orig |> Enum.map(& &1.text) |> List.to_tuple()
    {ai, bi} = lcs(a, List.to_tuple(corr))

    build_regions(orig, corr, Enum.zip(ai, bi), orig_bytes)
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

    region = %{
      before: before,
      after: after_,
      start: start,
      stop: stop,
      orig: {oi, mo},
      corr: {ci, mc}
    }

    [region | regions]
  end

  defp tokens_with_offsets(text) do
    ~r/\S+/u
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{s, l}] -> %{start: s, len: l, text: binary_part(text, s, l)} end)
  end

  # ── Metadata matching ─────────────────────────────────────────────────────
  # Each correction is located in the text (`before` among the original words, `after` among
  # the rewrite's), so a repeated word like a moved "ich" takes its own sentence's explanation.
  # A region nothing was located at falls back to the correction sharing the most words.
  defp match(regions, orig, corr, corrections) do
    orig_words = Enum.map(orig, &normalize(&1.text))
    corr_words = Enum.map(corr, &normalize/1)

    {located, _} =
      Enum.map_reduce(corrections, {0, 0}, fn c, {from_o, from_c} ->
        o = find_span(orig_words, needle(c["before"]), from_o)
        k = find_span(corr_words, needle(c["after"]), from_c)
        {{c, o, k}, {next(o, from_o), next(k, from_c)}}
      end)

    Enum.map(regions, fn r ->
      target = wordset(r.before, r.after)
      here = for {c, o, k} <- located, overlaps?(r.orig, o) or overlaps?(r.corr, k), do: c

      if(here == [], do: corrections, else: here)
      |> Enum.map(fn c ->
        words = wordset(c["before"], c["after"])
        {overlap(target, words), -MapSet.size(words), c}
      end)
      |> Enum.filter(fn {shared, _, _} -> shared > 0 end)
      |> Enum.max_by(fn {shared, smaller, _} -> {shared, smaller} end, fn -> nil end)
      |> case do
        {_, _, c} -> meta(c)
        nil -> %{"type" => "other", "explanation" => ""}
      end
    end)
  end

  defp find_span(_words, [], _from), do: nil

  defp find_span(words, needle, from) do
    span = fn from ->
      Enum.find_value(from..(length(words) - length(needle))//1, fn i ->
        if Enum.slice(words, i, length(needle)) == needle, do: {i, i + length(needle)}
      end)
    end

    span.(from) || span.(0)
  end

  defp next(nil, from), do: from
  defp next({start, _stop}, _from), do: start + 1

  defp overlaps?({a, b}, {s, e}), do: a < e and s < b
  defp overlaps?(_range, nil), do: false

  defp meta(c) do
    %{
      "type" => to_string(c["type"] || "other"),
      "explanation" => to_string(c["explanation"] || "")
    }
  end

  defp needle(nil), do: []

  defp needle(s),
    do: s |> to_string() |> String.split(~r/\s+/, trim: true) |> Enum.map(&normalize/1)

  # Case- and punctuation-blind, so "müde." in the text matches "müde" in a correction.
  defp normalize(word), do: word |> String.downcase() |> String.replace(~r/^\p{P}+|\p{P}+$/u, "")

  defp wordset(a, b), do: MapSet.new(needle(a) ++ needle(b)) |> MapSet.delete("")
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
