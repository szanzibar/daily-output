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

  describe "spec_for/2 (Settings choice → provider:model spec)" do
    test "direct routes to each vendor's own API" do
      assert AI.spec_for("direct", "glm-5.2") == "zai:glm-5.2"
      assert AI.spec_for("direct", "sonnet-4-6") == "anthropic:claude-sonnet-4-6"
    end

    test "openrouter routes to OpenRouter's slugs (dotted anthropic, dashed z-ai)" do
      assert AI.spec_for("openrouter", "glm-5.2") == "openrouter:z-ai/glm-5.2"
      assert AI.spec_for("openrouter", "sonnet-4-6") == "openrouter:anthropic/claude-sonnet-4.6"
    end

    test "unknown/nil values fall back to the default (direct + GLM 5.2)" do
      assert AI.spec_for(nil, nil) == "zai:glm-5.2"
      assert AI.spec_for("direct", "mystery") == "zai:glm-5.2"
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

  # Locks the ReqLLM → Anthropic-shape reshape against the REAL ReqLLM structs, so the
  # rest of the app (text_content/1, tool_use/1, Stats.record_usage/2) keeps working
  # unchanged. Builds genuine %ReqLLM.Response{} values — not hand-rolled maps — so a
  # future ReqLLM upgrade that changes an accessor breaks this test loudly.
  describe "anthropic_shape/2 (ReqLLM response reshape)" do
    defp req_response(message, usage) do
      %ReqLLM.Response{
        id: "resp_test",
        context: ReqLLM.Context.new([]),
        message: message,
        model: "anthropic:claude-sonnet-4-6",
        usage: usage
      }
    end

    test "text response becomes a text block that text_content/1 reads, with usage mapped" do
      response =
        req_response(
          ReqLLM.Context.assistant("Hoi zäme!"),
          %{input_tokens: 10, output_tokens: 4, cached_tokens: 2, cache_creation_tokens: 3}
        )

      shaped = AI.anthropic_shape(response, "claude-sonnet-4-6")

      assert AI.text_content(shaped) == "Hoi zäme!"
      assert AI.tool_use(shaped) == nil
      assert shaped["model"] == "anthropic:claude-sonnet-4-6"
      # ReqLLM's cached_tokens/cache_creation_tokens map to the Anthropic names Stats reads.
      assert shaped["usage"] == %{
               "input_tokens" => 10,
               "output_tokens" => 4,
               "cache_read_input_tokens" => 2,
               "cache_creation_input_tokens" => 3
             }
    end

    test "tool call becomes a tool_use block with decoded input that tool_use/1 reads" do
      tool_call =
        ReqLLM.ToolCall.new(
          "toolu_1",
          "provide_feedback",
          ~s({"annotated_text":"Ich [[hab||habe||verb||x]] gegessen","commentary":[]})
        )

      message = %{ReqLLM.Context.assistant("") | tool_calls: [tool_call]}
      response = req_response(message, %{input_tokens: 20, output_tokens: 30})

      shaped = AI.anthropic_shape(response, "claude-sonnet-4-6")

      assert AI.tool_use(shaped) == %{
               "annotated_text" => "Ich [[hab||habe||verb||x]] gegessen",
               "commentary" => []
             }

      # Missing cache fields default to 0 (never crashes Stats).
      assert shaped["usage"]["cache_read_input_tokens"] == 0
    end

    test "falls back to the requested model id when the response omits one" do
      response = %{req_response(ReqLLM.Context.assistant("x"), %{}) | model: nil}
      assert AI.anthropic_shape(response, "claude-sonnet-4-6")["model"] == "claude-sonnet-4-6"
    end
  end
end
