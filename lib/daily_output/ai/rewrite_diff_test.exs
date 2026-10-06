defmodule DailyOutput.AI.RewriteDiffTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.RewriteDiff
  alias DailyOutput.Markers

  # Markers reduced to the original must reproduce the student's text. An inserted word
  # leaves a harmless double space, so compare with spaces collapsed; newlines stay exact.
  defp to_before(annotated), do: Markers.original_text(annotated)

  defp collapse(s), do: String.replace(s, ~r/ +/, " ")

  test "clean sentence returns unchanged, no markers" do
    s = "Das Wetter ist heute sehr schön und ich gehe spazieren."
    assert RewriteDiff.annotate(s, s, []) == s
  end

  test "word-order + verb move never duplicates or garbles (the 235 failure)" do
    orig = "Gestern ich habe in die Stadt gegangen und habe ein neues Buch gekauft."
    corr = "Gestern bin ich in die Stadt gegangen und habe ein neues Buch gekauft."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{"after" => "bin", "type" => "verb", "explanation" => "Bewegungsverb braucht sein"},
        %{
          "before" => "habe",
          "after" => "",
          "type" => "word-order",
          "explanation" => "Verb an Position 2"
        }
      ])

    # Faithful: outside markers is exactly the student's text; nothing duplicated.
    assert collapse(to_before(annotated)) == collapse(orig)
    # Applying the corrections reproduces the rewrite.
    corrected = Regex.replace(~r/\[\[.*?\|\|(.*?)\|\|.*?\]\]/, annotated, "\\1")
    assert String.replace(corrected, ~r/\s+/, " ") == corr
  end

  test "insertion and capitalization, umlauts kept intact" do
    orig = "Die Schweizer grillieren verschiedene Arten Würste."
    corr = "Die Schweizer grillieren verschiedene Arten von Würsten."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{"after" => "von Würsten", "type" => "case", "explanation" => "Arten von + Dativ"}
      ])

    assert collapse(to_before(annotated)) == collapse(orig)
    assert annotated =~ "Würste"
  end

  test "line breaks in the original are preserved verbatim" do
    orig = "Hallo!\n\nIch habe ein Fehler gemacht."
    corr = "Hallo!\n\nIch habe einen Fehler gemacht."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{
          "before" => "ein",
          "after" => "einen",
          "type" => "case",
          "explanation" => "Akkusativ maskulin"
        }
      ])

    assert collapse(to_before(annotated)) == collapse(orig)
    assert annotated =~ "Hallo!\n\nIch"
  end

  test "a move's strike-half inherits the insertion's explanation (no empty markers)" do
    orig = "Ich hoffe, dass sie von mir geliebt sich gefühlt haben."
    corr = "Ich hoffe, dass sie sich von mir geliebt gefühlt haben."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{"after" => "sich", "type" => "word-order", "explanation" => "sich vor das Partizip"}
      ])

    assert collapse(to_before(annotated)) == collapse(orig)

    # Every marker carries an explanation.
    for %{explanation: e} <- Markers.parse(annotated), do: assert(e != "")
  end

  test "each repeated word move gets its own sentence's explanation" do
    orig =
      "Letzte Woche ich habe angefangen. Am ersten Tag ich bin gelaufen. Wenn ich Zeit hätte, ich würde trainieren."

    corr =
      "Letzte Woche habe ich angefangen. Am ersten Tag bin ich gelaufen. Wenn ich Zeit hätte, würde ich trainieren."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{
          "before" => "ich habe",
          "after" => "habe ich",
          "type" => "word-order",
          "explanation" => "nach Letzte Woche"
        },
        %{
          "before" => "ich bin",
          "after" => "bin ich",
          "type" => "word-order",
          "explanation" => "nach der Zeitangabe"
        },
        %{
          "before" => "hätte, ich würde",
          "after" => "hätte, würde ich",
          "type" => "word-order",
          "explanation" => "nach dem Nebensatz"
        }
      ])

    assert Enum.map(Markers.parse(annotated), & &1.explanation) ==
             [
               "nach Letzte Woche",
               "nach Letzte Woche",
               "nach der Zeitangabe",
               "nach der Zeitangabe",
               "nach dem Nebensatz",
               "nach dem Nebensatz"
             ]
  end

  test "a change next to punctuation still finds its explanation" do
    annotated =
      RewriteDiff.annotate("Videos von meinem Dirigent.", "Videos von meinem Dirigenten.", [
        %{
          "before" => "Dirigent",
          "after" => "Dirigenten",
          "type" => "case",
          "explanation" => "schwaches Maskulinum"
        }
      ])

    assert [%{explanation: "schwaches Maskulinum", category: "case"}] = Markers.parse(annotated)
  end
end
