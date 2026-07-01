defmodule DailyOutput.Flashcards.Markers do
  @moduledoc """
  Helpers for reading the inline-correction marker format produced by `AI.Proofreader`.

  A marker is self-contained: `[[before||after||type||explanation]]`
    * REPLACE — both sides filled: `[[das||dass||grammar||...]]`
    * INSERT  — before side empty: `[[||,||punctuation||...]]`
    * DELETE  — after side empty:  `[[extra||||vocabulary||...]]`

  `type` and `explanation` are optional trailing fields (default `"other"`/`""`), matching
  `AI.Proofreader`'s own tolerant parser — the two must stay in sync. Pure and
  language-agnostic.
  """

  @marker ~r/\[\[([\s\S]*?)\]\]/

  @doc """
  Reduces annotated text to its fully-corrected form by applying every marker
  (REPLACE/INSERT keep the `after` side, DELETE drops the `before`).
  """
  def corrected_text(nil), do: ""

  def corrected_text(text) when is_binary(text) do
    Regex.replace(@marker, text, fn whole, inner ->
      case parts(inner) do
        {_before, after_, _type, _expl} -> after_
        :malformed -> whole
      end
    end)
  end

  @doc """
  Parses the markers into `[%{original, corrected, category, explanation}]` — the exact shape
  `Generator.generate/3` wants as its mistakes list. No-op markers (before == after, the model
  flagging then keeping text) and malformed markers are dropped.
  """
  def parse(nil), do: []

  def parse(text) when is_binary(text) do
    @marker
    |> Regex.scan(text)
    |> Enum.flat_map(fn [_full, inner] ->
      case parts(inner) do
        {before, after_, _type, _expl} when before == after_ ->
          []

        {before, after_, type, expl} ->
          [%{original: before, corrected: after_, category: type, explanation: String.trim(expl)}]

        :malformed ->
          []
      end
    end)
  end

  # Inner of a marker -> {before, after, type, explanation}; trailing fields default so a
  # 2- or 3-field marker still parses. Mirrors `AI.Proofreader.marker_parts/1`.
  defp parts(inner) do
    case String.split(inner, "||", parts: 4) do
      [before, after_, type, expl] -> {before, after_, type, expl}
      [before, after_, type] -> {before, after_, type, ""}
      [before, after_] -> {before, after_, "other", ""}
      _ -> :malformed
    end
  end

  @doc """
  True when the only difference between `original` and `corrected` is letter casing
  (e.g. a missed noun capitalization) — these are not worth a flashcard.

  Insertions/deletions (one side empty) are never capitalization-only.
  """
  def capitalization_only?(original, corrected) do
    o = String.trim(original || "")
    c = String.trim(corrected || "")
    o != "" and c != "" and o != c and String.downcase(o) == String.downcase(c)
  end

  @doc "The markers that represent a substantive (non-capitalization-only) correction."
  def substantive(markers) do
    Enum.reject(markers, &capitalization_only?(&1.original, &1.corrected))
  end
end
