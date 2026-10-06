defmodule DailyOutput.AI.ProofreaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DailyOutput.AI.Proofreader

  describe "parse_message_feedback/1" do
    test "keeps markers inline in annotated_text and derives a flat annotations list" do
      text =
        "Ich [[gehe||ging||verb||Präteritum für Vergangenheit]] gestern ins Kino und " <>
          "[[||es||other||Subjekt «es» fehlt]] war schön."

      result = Proofreader.parse_message_feedback(text)

      # markers stay inline — the front end reads each marker's own explanation, no id needed
      assert result["annotated_text"] == text

      assert result["annotations"] == [
               %{"category" => "verb", "explanation" => "Präteritum für Vergangenheit"},
               %{"category" => "other", "explanation" => "Subjekt «es» fehlt"}
             ]
    end

    test "no markers means the message was clean (no annotations)" do
      result = Proofreader.parse_message_feedback("Alles korrekt hier.")
      assert result == %{"annotated_text" => "Alles korrekt hier.", "annotations" => []}
    end

    test "explanation may itself contain pipes (it is the last field)" do
      text = "Test [[a||b||case||use «a | b» not «c»]]"
      result = Proofreader.parse_message_feedback(text)

      assert result["annotated_text"] == text

      assert result["annotations"] == [
               %{"category" => "case", "explanation" => "use «a | b» not «c»"}
             ]
    end

    test "a 2-field marker still renders and counts as an 'other' correction" do
      result = Proofreader.parse_message_feedback("Ich [[gehe||ging]] heim.")
      assert result["annotated_text"] == "Ich [[gehe||ging]] heim."
      assert result["annotations"] == [%{"category" => "other", "explanation" => ""}]
    end

    test "no-op markers (before == after) are dropped to plain text" do
      result =
        Proofreader.parse_message_feedback(
          "Ich gehe [[in die Stadt||in die Stadt||preposition||eigentlich korrekt]] heute."
        )

      assert result["annotated_text"] == "Ich gehe in die Stadt heute."
      assert result["annotations"] == []
    end

    test "delete form (empty after) keeps the marker inline and is annotated" do
      result = Proofreader.parse_message_feedback("Ich [[sehr ||||other||überflüssig]]gut.")
      assert result["annotated_text"] == "Ich [[sehr ||||other||überflüssig]]gut."
      assert result["annotations"] == [%{"category" => "other", "explanation" => "überflüssig"}]
    end

    test "an unknown type normalizes to 'other'" do
      result = Proofreader.parse_message_feedback("Ich [[hab||habe||conjugation||fix]] es.")
      assert result["annotations"] == [%{"category" => "other", "explanation" => "fix"}]
    end

    test "non-binary input yields empty feedback" do
      assert Proofreader.parse_message_feedback(nil) == %{
               "annotated_text" => "",
               "annotations" => []
             }
    end
  end

  describe "rewrite_feedback/2" do
    test "builds inline markers from the rewrite" do
      input = %{
        "corrected" => "Gestern bin ich gegangen.",
        "corrections" => [
          %{"before" => "habe", "after" => "bin", "type" => "verb", "explanation" => "sein"}
        ]
      }

      assert {:ok, %{"annotated_text" => annotated, "annotations" => [%{"category" => "verb"}]}} =
               Proofreader.rewrite_feedback(input, "Gestern habe ich gegangen.")

      assert annotated =~ "[[habe||bin||verb||sein]]"
    end

    test "an empty rewrite is a parse miss, not an uncorrected message" do
      capture_log(fn ->
        assert Proofreader.rewrite_feedback(%{"corrected" => "", "corrections" => []}, "Hallo") ==
                 {:error, :unparsed}
      end)
    end
  end

  describe "normalize_message_feedback/1" do
    test "passes through annotated_text and a list of annotations" do
      input = %{
        "annotated_text" => "Ich [[1:gehe||ging]] heim.",
        "annotations" => [%{"id" => 1, "explanation" => "Vergangenheit", "category" => "verb"}]
      }

      result = Proofreader.normalize_message_feedback(input)
      assert result["annotated_text"] == "Ich [[1:gehe||ging]] heim."
      assert [%{"category" => "verb"}] = result["annotations"]
    end

    test "drops non-map entries from the annotations list" do
      input = %{
        "annotated_text" => "Test",
        "annotations" => [%{"id" => 1, "explanation" => "fix", "category" => "case"}, "junk"]
      }

      result = Proofreader.normalize_message_feedback(input)
      assert [%{"id" => 1, "category" => "case"}] = result["annotations"]
    end

    test "yields no annotations when the field is not a structured list" do
      # We prevent stringified/mangled output up front; if it slips through we show
      # nothing for that message rather than rendering garbage.
      input = %{"annotated_text" => "Test", "annotations" => ~s([{"id":1}])}
      assert Proofreader.normalize_message_feedback(input)["annotations"] == []
    end

    test "defaults missing fields to empty" do
      result = Proofreader.normalize_message_feedback(%{})
      assert result == %{"annotated_text" => "", "annotations" => []}
    end

    test "nil stays nil" do
      assert Proofreader.normalize_message_feedback(nil) == nil
    end

    test "coerces an unknown category to \"other\"" do
      result =
        Proofreader.normalize_message_feedback(%{
          "annotated_text" => "...",
          "annotations" => [%{"id" => 1, "explanation" => "x", "category" => "bogus"}]
        })

      assert [%{"category" => "other"}] = result["annotations"]
    end
  end

  describe "journal_schema/0 and review_schema/0" do
    test "the journal asks for a rewrite plus the wrap-up, no tips" do
      schema = Proofreader.journal_schema()

      # annotations/annotated_text are derived from the diff (RewriteDiff), not schema fields.
      assert schema["required"] == ["corrected", "corrections", "summary", "focus_result"]
      assert Enum.sort(Map.keys(schema["properties"])) == Enum.sort(schema["required"])
    end

    test "the conversation review only wraps up" do
      assert Proofreader.review_schema()["required"] == ["summary", "focus_result"]
    end
  end

  describe "normalize_review/1" do
    test "trims the summary and comment" do
      assert Proofreader.normalize_review(%{
               "summary" => " You told me about Lucerne. ",
               "focus_result" => %{"used" => true, "correct" => true, "comment" => " Gut! "}
             }) == %{
               "summary" => "You told me about Lucerne.",
               "focus_result" => %{"used" => true, "correct" => true, "comment" => "Gut!"}
             }
    end

    test "an unused focus is never correct" do
      review =
        Proofreader.normalize_review(%{
          "summary" => "x",
          "focus_result" => %{"used" => false, "correct" => true, "comment" => "x"}
        })

      assert review["focus_result"]["correct"] == false
    end
  end
end
