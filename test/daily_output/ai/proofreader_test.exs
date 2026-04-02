defmodule DailyOutput.AI.ProofreaderTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.Proofreader

  describe "feedback_tool/1" do
    test "without focus topic, focus_result is not required" do
      tool = Proofreader.feedback_tool(nil)

      assert tool.input_schema["required"] ==
               ["annotated_text", "annotations", "commentary", "encouragement"]

      refute Map.has_key?(tool.input_schema["properties"], "focus_result")
    end

    test "with focus topic, focus_result is required" do
      tool = Proofreader.feedback_tool("Nebensatzkonnektoren")

      assert "focus_result" in tool.input_schema["required"]
      focus_props = tool.input_schema["properties"]["focus_result"]["properties"]
      assert Map.has_key?(focus_props, "used")
      assert Map.has_key?(focus_props, "correct")
      assert Map.has_key?(focus_props, "comment")
    end

    test "with empty string focus topic, focus_result is not required" do
      tool = Proofreader.feedback_tool("")
      refute "focus_result" in tool.input_schema["required"]
    end

    test "commentary type is constrained to valid values" do
      tool = Proofreader.feedback_tool(nil)
      commentary_props = tool.input_schema["properties"]["commentary"]["items"]["properties"]
      assert commentary_props["type"]["enum"] == ["pattern", "suggestion", "alternative"]
    end
  end

  describe "normalize_feedback/1" do
    test "passes through complete feedback" do
      input = %{
        "annotated_text" => "Ich [[1:gehe||ging]] nach Hause.",
        "annotations" => [%{"id" => 1, "explanation" => "Vergangenheitsform"}],
        "commentary" => [%{"type" => "pattern", "text" => "Achte auf Zeitformen."}],
        "encouragement" => "Gut gemacht!"
      }

      result = Proofreader.normalize_feedback(input)
      assert result["annotated_text"] == "Ich [[1:gehe||ging]] nach Hause."
      assert length(result["annotations"]) == 1
      assert result["encouragement"] == "Gut gemacht!"
      refute Map.has_key?(result, "focus_result")
    end

    test "includes focus_result when present" do
      input = %{
        "annotated_text" => "Test.",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Toll!",
        "focus_result" => %{"used" => true, "correct" => true, "comment" => "Gut!"}
      }

      result = Proofreader.normalize_feedback(input)
      assert result["focus_result"]["used"] == true
      assert result["focus_result"]["correct"] == true
    end

    test "defaults missing fields" do
      result = Proofreader.normalize_feedback(%{})
      assert result["annotated_text"] == ""
      assert result["annotations"] == []
      assert result["commentary"] == []
      assert result["encouragement"] == ""
      refute Map.has_key?(result, "focus_result")
    end

    test "handles German text with quotes" do
      input = %{
        "annotated_text" => "Und (wie sagt man \u201Eso far\u201C) geht es gut.",
        "commentary" => [
          %{
            "type" => "pattern",
            "text" => "\u201Ees ist gut, h\u00F6her singen zu lernen.\u201C braucht ein Komma."
          }
        ],
        "annotations" => [],
        "encouragement" => "Sehr gut!",
        "focus_result" => %{"used" => true, "correct" => false, "comment" => "Fast!"}
      }

      result = Proofreader.normalize_feedback(input)
      assert result["focus_result"]["used"] == true
      assert result["focus_result"]["correct"] == false
    end
  end
end
