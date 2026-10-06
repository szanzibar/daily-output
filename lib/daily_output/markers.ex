defmodule DailyOutput.Markers do
  @moduledoc """
  Reads the inline corrections `AI.RewriteDiff` writes into `annotated_text`:
  `[[before||after||type||explanation]]`. An empty `before` is an insert, an empty `after` a
  delete. Everything that reads corrections goes through here.

  A student who types `[[` or `||` breaks the parse. Known and accepted.
  """

  @marker ~r/\[\[([\s\S]*?)\]\]/

  @doc "The corrections in `text`, in order, as `%{original, corrected, category, explanation}`."
  def parse(text), do: for([_, inner] <- Regex.scan(@marker, text), do: correction(inner))

  @doc "`text` as the student wrote it."
  def original_text(text),
    do: Regex.replace(@marker, text, fn _, inner -> correction(inner).original end)

  @doc """
  The corrected sentences that had a substantive correction, so a card never drills a
  sentence the student already got right.
  """
  def mistake_sentences(text) do
    # A control char flags each fix, so the sentence split runs on plain corrected text.
    Regex.replace(@marker, text, fn _, inner ->
      %{original: original, corrected: corrected} = correction(inner)
      if capitalization_only?(original, corrected), do: corrected, else: "\u0001" <> corrected
    end)
    |> String.split(~r/(?<=[.!?])\s+|\n/u, trim: true)
    |> Enum.filter(&String.contains?(&1, "\u0001"))
    |> Enum.map(
      &(&1
        |> String.replace("\u0001", "")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim())
    )
  end

  @doc "The corrections that change more than letter case. A case-only fix isn't worth a card."
  def substantive(corrections) do
    Enum.reject(corrections, &capitalization_only?(&1.original, &1.corrected))
  end

  # An insert or delete is never capitalization-only.
  defp capitalization_only?(original, corrected) do
    original != "" and corrected != "" and String.downcase(original) == String.downcase(corrected)
  end

  defp correction(inner) do
    [original, corrected, category, explanation] = String.split(inner, "||", parts: 4)
    %{original: original, corrected: corrected, category: category, explanation: explanation}
  end
end
