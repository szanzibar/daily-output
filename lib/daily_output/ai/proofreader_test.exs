defmodule DailyOutput.AI.ProofreaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DailyOutput.AI.Proofreader

  describe "rewrite_feedback/2" do
    test "builds inline markers from the rewrite" do
      input = %{
        "corrected" => "Gestern bin ich gegangen.",
        "corrections" => [
          %{"before" => "habe", "after" => "bin", "type" => "verb", "explanation" => "sein"}
        ]
      }

      assert Proofreader.rewrite_feedback(input, "Gestern habe ich gegangen.") ==
               {:ok, %{"annotated_text" => "Gestern [[habe||bin||verb||sein]] ich gegangen."}}
    end

    test "an empty rewrite is a parse miss, not an uncorrected message" do
      capture_log(fn ->
        assert Proofreader.rewrite_feedback(%{"corrected" => "", "corrections" => []}, "Hallo") ==
                 {:error, :unparsed}
      end)
    end
  end

  describe "journal_schema/0 and review_schema/0" do
    test "the journal asks for a rewrite plus the wrap-up, no tips" do
      schema = Proofreader.journal_schema()

      # annotated_text comes from the diff (RewriteDiff), not a schema field.
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
