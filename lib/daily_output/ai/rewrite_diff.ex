defmodule DailyOutput.AI.RewriteDiff do
  @moduledoc """
  Turns a model's rewrite of the student's text into the inline correction markers
  `Markers` reads, `[[before||after||type||explanation]]`. The model can't place markers
  around a word-order move without garbling them, so it only rewrites and lists its changes,
  and the spans come from a word diff here.
  """

  @doc """
  Builds `annotated_text` for `original` given the model's `corrected` rewrite and its
  `corrections` list (`[%{"before" => ..., "after" => ..., "type" => ..., "explanation" => ...}]`).
  Spans come from the diff; type/explanation are matched to each span from the list. Outside
  the markers the original stays verbatim, line breaks included.
  """
  def annotate(original, corrected, corrections) do
    orig = tokens_with_offsets(original)
    corr = Enum.map(tokens_with_offsets(corrected), & &1.text)
    regions = regions(orig, corr, byte_size(original))
    metas = match(regions, orig, corr, corrections)

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

    out <> binary_part(original, cursor, byte_size(original) - cursor)
  end

  defp marker(before, after_, %{"type" => type, "explanation" => expl}) do
    "[[#{before}||#{after_}||#{type}||#{String.trim(expl)}]]"
  end

  # ── Region diff ─────────────────────────────────────────────────────────────
  # Word tokens of the original carry their byte offset so the rebuild preserves every
  # original space/newline outside a region. The rewrite is compared by word text only, and
  # case-sensitively, because a capital is a real correction here.
  defp regions(orig, corr, orig_bytes) do
    orig
    |> Enum.map(& &1.text)
    |> List.myers_difference(corr)
    |> Enum.chunk_by(&(elem(&1, 0) == :eq))
    |> Enum.flat_map_reduce({0, 0}, fn
      [{:eq, words}], {oi, ci} ->
        {[], {oi + length(words), ci + length(words)}}

      # A run of deleted and inserted words between two kept ones is one region.
      changes, {oi, ci} ->
        mo = oi + Enum.sum(for {:del, words} <- changes, do: length(words))
        mc = ci + Enum.sum(for {:ins, words} <- changes, do: length(words))
        {[region(orig, corr, oi, mo, ci, mc, orig_bytes)], {mo, mc}}
    end)
    |> elem(0)
  end

  # Region for deleted original words [oi, mo) and inserted rewrite words [ci, mc).
  defp region(orig, corr, oi, mo, ci, mc, orig_bytes) do
    del = Enum.slice(orig, oi, mo - oi)
    ins = Enum.slice(corr, ci, mc - ci)

    {start, stop} =
      case del do
        [] ->
          # pure insertion: anchor at the start of the next original word (or end of text)
          point = if mo < length(orig), do: Enum.at(orig, mo).start, else: orig_bytes
          {point, point}

        _ ->
          last = List.last(del)
          {hd(del).start, last.start + last.len}
      end

    %{
      before: Enum.map_join(del, " ", & &1.text),
      after: Enum.join(ins, " "),
      start: start,
      stop: stop,
      orig: {oi, mo},
      corr: {ci, mc}
    }
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
end
