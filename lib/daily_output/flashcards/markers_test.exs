defmodule DailyOutput.Flashcards.MarkersTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Markers

  describe "corrected_text/1" do
    test "applies replace, insert, and delete markers" do
      text = "Ich [[gehe||ging||verb||v]] heim[[||,||punctuation||p]] [[sehr ||||word||w]]müde."
      assert Markers.corrected_text(text) == "Ich ging heim, müde."
    end

    test "returns plain text unchanged" do
      assert Markers.corrected_text("Alles korrekt.") == "Alles korrekt."
    end

    test "handles nil" do
      assert Markers.corrected_text(nil) == ""
    end
  end

  describe "parse/1" do
    test "extracts original, corrected, category, and explanation" do
      assert [
               %{original: "das", corrected: "dass", category: "grammar", explanation: "conj"},
               %{original: "", corrected: ",", category: "punctuation", explanation: "comma"}
             ] =
               Markers.parse(
                 "Ich glaube [[das||dass||grammar||conj]] es klappt[[||,||punctuation||comma]]"
               )
    end

    test "drops no-op markers (before == after)" do
      assert Markers.parse("Alles [[gut||gut||none||]] hier") == []
    end
  end

  describe "capitalization_only?/2" do
    test "true when only the case differs" do
      assert Markers.capitalization_only?("haus", "Haus")
    end

    test "false for substantive changes" do
      refute Markers.capitalization_only?("das", "dass")
    end

    test "false for inserts/deletes and identical text" do
      refute Markers.capitalization_only?("", "Haus")
      refute Markers.capitalization_only?("Haus", "")
      refute Markers.capitalization_only?("Haus", "Haus")
    end
  end

  test "substantive/1 drops capitalization-only markers" do
    markers =
      Markers.parse("Das [[haus||Haus||spelling||cap]] ist [[gross||groß||spelling||ss]].")

    assert [%{corrected: "groß"}] = Markers.substantive(markers)
  end
end
