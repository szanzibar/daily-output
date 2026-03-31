defmodule Sprachjournal.AI.ProofreaderTest do
  use ExUnit.Case, async: true

  alias Sprachjournal.AI.Proofreader

  describe "parse_feedback/1" do
    @valid_json Jason.encode!(%{
      "annotated_text" => "Ich [[1:gehe||ging]] nach Hause.",
      "annotations" => [%{"id" => 1, "explanation" => "Vergangenheitsform nötig"}],
      "commentary" => [%{"type" => "pattern", "text" => "Achte auf Zeitformen."}],
      "encouragement" => "Gut gemacht!"
    })

    test "parses valid JSON response" do
      assert {:ok, feedback} = Proofreader.parse_feedback(@valid_json)
      assert feedback["annotated_text"] == "Ich [[1:gehe||ging]] nach Hause."
      assert length(feedback["annotations"]) == 1
      assert feedback["encouragement"] == "Gut gemacht!"
    end

    test "parses response with focus_result" do
      json = Jason.encode!(%{
        "annotated_text" => "Ich bin müde.",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Toll!",
        "focus_result" => %{"used" => true, "correct" => true, "comment" => "Gut verwendet!"}
      })

      assert {:ok, feedback} = Proofreader.parse_feedback(json)
      assert feedback["focus_result"]["used"] == true
      assert feedback["focus_result"]["correct"] == true
      assert feedback["focus_result"]["comment"] == "Gut verwendet!"
    end

    test "handles true/false literals in focus_result" do
      # This is the actual bug: the LLM outputs literal true/false instead of a boolean
      bad_json = """
      {
        "annotated_text": "Ich bin müde.",
        "annotations": [],
        "commentary": [],
        "encouragement": "Toll!",
        "focus_result": {"used": true/false, "correct": true/false, "comment": "Konnte nicht beurteilt werden"}
      }
      """

      assert {:ok, feedback} = Proofreader.parse_feedback(bad_json)
      assert feedback["annotated_text"] == "Ich bin müde."
      assert feedback["focus_result"]["used"] == false
      assert feedback["focus_result"]["comment"] == "Konnte nicht beurteilt werden"
    end

    test "strips markdown code fences" do
      wrapped = "```json\n#{@valid_json}\n```"

      assert {:ok, feedback} = Proofreader.parse_feedback(wrapped)
      assert feedback["annotated_text"] == "Ich [[1:gehe||ging]] nach Hause."
    end

    test "strips markdown code fences with trailing newline" do
      wrapped = "```json\n#{@valid_json}\n```\n\n\n"

      assert {:ok, feedback} = Proofreader.parse_feedback(wrapped)
      assert feedback["annotated_text"] == "Ich [[1:gehe||ging]] nach Hause."
    end

    test "strips markdown code fences with focus_result" do
      json = Jason.encode!(%{
        "annotated_text" => "Test",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Gut!",
        "focus_result" => %{"used" => false, "correct" => false, "comment" => "Nicht verwendet"}
      })

      wrapped = "```json\n#{json}\n```"

      assert {:ok, feedback} = Proofreader.parse_feedback(wrapped)
      assert feedback["focus_result"]["used"] == false
    end

    test "returns error for completely invalid response" do
      assert {:error, :no_json_found} = Proofreader.parse_feedback("no json here at all")
    end

    test "returns error for malformed JSON that can't be repaired" do
      assert {:error, :invalid_json} = Proofreader.parse_feedback("{not: valid, json: at all}")
    end

    test "normalizes missing fields to defaults" do
      json = Jason.encode!(%{"annotated_text" => "Hallo"})

      assert {:ok, feedback} = Proofreader.parse_feedback(json)
      assert feedback["annotated_text"] == "Hallo"
      assert feedback["annotations"] == []
      assert feedback["commentary"] == []
      assert feedback["encouragement"] == ""
      refute Map.has_key?(feedback, "focus_result")
    end

    test "extracts JSON when LLM includes surrounding text" do
      response = """
      Here is my feedback:
      {"annotated_text": "Hallo", "annotations": [], "commentary": [], "encouragement": "Gut!"}
      I hope this helps!
      """

      assert {:ok, feedback} = Proofreader.parse_feedback(response)
      assert feedback["annotated_text"] == "Hallo"
    end
  end
end
