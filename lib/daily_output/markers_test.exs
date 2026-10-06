defmodule DailyOutput.MarkersTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Markers

  test "parse/1 reads every correction, inserts and deletes included" do
    assert Markers.parse(
             "Ich glaube [[das||dass||grammar||conj]] es klappt[[||,||punctuation||a | b]]"
           ) ==
             [
               %{original: "das", corrected: "dass", category: "grammar", explanation: "conj"},
               %{original: "", corrected: ",", category: "punctuation", explanation: "a | b"}
             ]

    assert Markers.parse("Alles korrekt.") == []
  end

  test "original_text/1 is what the student wrote" do
    text = "Ich [[gehe||ging||verb||v]] heim[[||,||punctuation||p]] [[sehr ||||word||w]]müde."
    assert Markers.original_text(text) == "Ich gehe heim sehr müde."
  end

  test "mistake_sentences/1 keeps only the corrected sentences that had a substantive fix" do
    text =
      "Wir haben einen Film geschaut. Ich mag [[sehr||||word-order||x]] seine " <>
        "[[Filme,||Filme sehr,||word-order||x]] weil sie [[sind spannend.||spannend sind.||word-order||y]]" <>
        "\nDas [[haus||Haus||spelling||c]] ist schön."

    assert Markers.mistake_sentences(text) == [
             "Ich mag seine Filme sehr, weil sie spannend sind."
           ]
  end

  test "substantive/1 drops capitalization-only fixes, never inserts or deletes" do
    corrections =
      Markers.parse(
        "Das [[haus||Haus||spelling||cap]] ist [[gross||groß||spelling||ss]][[||!||punctuation||p]] [[Haus||||other||d]]"
      )

    assert Enum.map(Markers.substantive(corrections), & &1.corrected) == ["groß", "!", ""]
  end
end
