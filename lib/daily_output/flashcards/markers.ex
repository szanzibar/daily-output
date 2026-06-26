defmodule DailyOutput.Flashcards.Markers do
  @moduledoc """
  Helpers for reading the inline-correction marker format produced by `AI.Proofreader`.

  A marker is `[[N:original||corrected]]`:
    * REPLACE — both sides filled: `[[1:das||dass]]`
    * INSERT  — original side empty: `[[2:||,]]`
    * DELETE  — corrected side empty: `[[3:extra||]]`

  Pure and language-agnostic.
  """

  @marker_regex ~r/\[\[(\d+):(.*?)\|\|(.*?)\]\]/s

  @doc """
  Reduces annotated text to its fully-corrected form by applying every marker
  (REPLACE/INSERT keep the corrected side, DELETE drops the original).
  """
  def corrected_text(nil), do: ""

  def corrected_text(text) when is_binary(text) do
    Regex.replace(@marker_regex, text, fn _full, _id, _original, corrected -> corrected end)
  end

  @doc "Parses the markers into `[%{id, original, corrected}]`."
  def parse(nil), do: []

  def parse(text) when is_binary(text) do
    @marker_regex
    |> Regex.scan(text)
    |> Enum.map(fn [_full, id, original, corrected] ->
      %{id: id, original: original, corrected: corrected}
    end)
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
