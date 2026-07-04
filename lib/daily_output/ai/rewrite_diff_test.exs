defmodule DailyOutput.AI.RewriteDiffTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.RewriteDiff
  alias DailyOutput.Flashcards.Markers

  @marker ~r/\[\[([\s\S]*?)\]\]/

  # Reduce markers to the `before` side — must reproduce the student's original (an inserted
  # word leaves a harmless double space, so compare with horizontal spaces collapsed; newlines
  # are asserted separately and must stay exact).
  defp to_before(annotated) do
    Regex.replace(@marker, annotated, fn _w, inner ->
      inner |> String.split("||") |> List.first()
    end)
  end

  defp collapse(s), do: String.replace(s, ~r/ +/, " ")

  defp malformed?(annotated) do
    @marker
    |> Regex.scan(annotated)
    |> Enum.any?(fn [_, inner] -> length(String.split(inner, "||")) < 4 end)
  end

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
    refute malformed?(annotated)
    # Applying the corrections reproduces the rewrite.
    assert Markers.corrected_text(annotated) |> String.replace(~r/\s+/, " ") ==
             corr |> String.replace(~r/\s+/, " ")
  end

  test "insertion and capitalization, umlauts kept intact" do
    orig = "Die Schweizer grillieren verschiedene Arten Würste."
    corr = "Die Schweizer grillieren verschiedene Arten von Würsten."

    annotated =
      RewriteDiff.annotate(orig, corr, [
        %{"after" => "von Würsten", "type" => "case", "explanation" => "Arten von + Dativ"}
      ])

    assert collapse(to_before(annotated)) == collapse(orig)
    refute malformed?(annotated)
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

    # Every substantive marker carries a non-empty explanation.
    for %{explanation: e, original: o, corrected: c} <- Markers.parse(annotated), o != c do
      assert String.trim(e) != ""
    end
  end
end
