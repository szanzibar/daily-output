defmodule DailyOutput.AITest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI

  describe "text_content/1" do
    test "returns text when a thinking block precedes it (sonnet-5 default)" do
      # Regression: thinking-enabled models emit a `thinking` block first, so
      # callers must not assume content starts with text.
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
          %{"type" => "text", "text" => "Hoi! Wie gohts?"}
        ]
      }

      assert AI.text_content(response) == "Hoi! Wie gohts?"
    end

    test "returns text when it is the only block" do
      response = %{"content" => [%{"type" => "text", "text" => "hello"}]}
      assert AI.text_content(response) == "hello"
    end

    test "concatenates multiple text blocks" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "foo"},
          %{"type" => "text", "text" => "bar"}
        ]
      }

      assert AI.text_content(response) == "foobar"
    end

    test "returns empty string when there is no text block" do
      response = %{"content" => [%{"type" => "thinking", "thinking" => "hmm"}]}
      assert AI.text_content(response) == ""
    end
  end

  describe "tool_use/1" do
    test "returns the input map even when a thinking block precedes tool_use" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
          %{"type" => "tool_use", "name" => "provide_flashcards", "input" => %{"cards" => []}}
        ]
      }

      assert AI.tool_use(response) == %{"cards" => []}
    end

    test "returns nil when there is no tool_use block" do
      response = %{"content" => [%{"type" => "text", "text" => "hi"}]}
      assert AI.tool_use(response) == nil
    end
  end
end
