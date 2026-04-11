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

    test "decodes stringified commentary from API response" do
      # The model sometimes returns arrays as JSON strings instead of structured data.
      # After Ecto decodes the outer JSON, German typographic quotes like „App"
      # contain bare ASCII " (U+0022) making Jason.decode fail on the inner string.
      stringified_commentary =
        "[\n  {\n    \"type\": \"pattern\",\n    \"text\": \"Das Genus von \u201eApp\" ist feminin: **die App**. Daher braucht man die feminine Form des unbestimmten Artikels und des Demonstrativpronomens: \u201eeine App\", \u201ediese App\". Merke: Viele englische Lehnwörter auf -App, -Mail oder -Cloud sind im Deutschen feminin.\"\n  },\n  {\n    \"type\": \"pattern\",\n    \"text\": \"Die Konstruktion \u201eum … zu + Infinitiv\" drückt einen Zweck aus. Das Verb steht immer am Ende: \u201eum **mir** zu **helfen**\". Vergleiche: \u201eIch lerne Deutsch, um einen Job zu finden.\" Das Reflexivpronomen oder Objekt steht direkt nach \u201eum\".\"\n  },\n  {\n    \"type\": \"pattern\",\n    \"text\": \"Sprachen werden im Deutschen immer grossgeschrieben, wenn sie als Substantiv stehen: **Deutsch**, **Englisch**, **Französisch**. Nur in der Wendung \u201eauf Deutsch\" oder \u201eer spricht deutsch\" (als Adverb) kann man kleinschreiben – aber im Zweifel: Grossschreibung ist immer sicher.\"\n  },\n  {\n    \"type\": \"suggestion\",\n    \"text\": \"Für \u201egenerate\" im Kontext von Sprachübungen könnte man sagen: \u201eWie sage ich \u201Agenerieren\u2018 auf Deutsch?\" oder einfach **generieren** verwenden – das Wort ist im Deutschen völlig gebräuchlich, z. B. \u201eKannst du mir einen Text generieren?\"\"\n  },\n  {\n    \"type\": \"alternative\",\n    \"text\": \"\u201eIch will mehr Deutsch üben\" ist korrekt und natürlich. Noch etwas idiomatischer wäre: \u201eIch möchte mein Deutsch verbessern\" oder \u201eIch will meine Deutschkenntnisse ausbauen\" – aber deine Version ist völlig verständlich und gut!\"\n  }\n]"

      stringified_annotations =
        "[\n  {\"id\": 1, \"explanation\": \"\u201eApp\" ist feminin: die App\"},\n  {\"id\": 2, \"explanation\": \"Femininform: eine App\"}\n]"

      input = %{
        "annotated_text" => "Test text",
        "annotations" => stringified_annotations,
        "commentary" => stringified_commentary,
        "encouragement" => "Gut gemacht!"
      }

      result = Proofreader.normalize_feedback(input)

      assert is_list(result["commentary"])
      assert length(result["commentary"]) == 5
      assert Enum.all?(result["commentary"], &is_map/1)

      assert Enum.all?(
               result["commentary"],
               &(Map.has_key?(&1, "type") and Map.has_key?(&1, "text"))
             )

      assert hd(result["commentary"])["type"] == "pattern"
      assert String.contains?(hd(result["commentary"])["text"], "die App")

      assert is_list(result["annotations"])
      assert length(result["annotations"]) == 2
      assert hd(result["annotations"])["id"] == 1
    end

    test "decodes valid JSON strings for commentary and annotations" do
      input = %{
        "annotated_text" => "Test",
        "annotations" => ~s([{"id": 1, "explanation": "fix"}]),
        "commentary" => ~s([{"type": "pattern", "text": "a tip"}]),
        "encouragement" => "Nice!"
      }

      result = Proofreader.normalize_feedback(input)

      assert is_list(result["commentary"])
      assert hd(result["commentary"])["type"] == "pattern"
      assert is_list(result["annotations"])
      assert hd(result["annotations"])["id"] == 1
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
