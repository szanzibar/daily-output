defmodule DailyOutput.Flashcards.MarkersTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Markers

  describe "corrected_text/1" do
    test "applies replace, insert, and delete markers" do
      text = "Ich [[1:gehe||ging]] heim[[2:||,]] [[3:sehr ||]]müde."
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
    test "extracts id, original, and corrected" do
      assert [
               %{id: "1", original: "das", corrected: "dass"},
               %{id: "2", original: "", corrected: ","}
             ] =
               Markers.parse("Ich glaube [[1:das||dass]] es klappt[[2:||,]]")
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
    markers = Markers.parse("Das [[1:haus||Haus]] ist [[2:gross||groß]].")
    assert [%{corrected: "groß"}] = Markers.substantive(markers)
  end
end
