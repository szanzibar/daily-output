defmodule DailyOutput.AITest do
  # Not async: the key lookup test sets global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DailyOutput.AI

  describe "text_content/1" do
    test "returns text when a thinking block precedes it" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
          %{"type" => "text", "text" => "Hoi! Wie gohts?"}
        ]
      }

      assert AI.text_content(response) == "Hoi! Wie gohts?"
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

  describe "spec_for/2" do
    test "direct routes to each vendor's own API" do
      assert AI.spec_for("direct", "sonnet-5.5") == "anthropic:claude-sonnet-5-5"
      assert AI.spec_for("direct", "gpt-5.6-luna") == "openai:gpt-5.6-luna"
    end

    test "openrouter routes to OpenRouter's slugs" do
      assert AI.spec_for("openrouter", "sonnet-5.5") == "openrouter:anthropic/claude-sonnet-5.5"
      assert AI.spec_for("openrouter", "gpt-5.6-luna") == "openrouter:openai/gpt-5.6-luna"
    end

    test "unknown or retired values fall back to direct Sonnet 5.5" do
      assert AI.spec_for(nil, nil) == "anthropic:claude-sonnet-5-5"
      assert AI.spec_for("direct", "glm-5.2") == "anthropic:claude-sonnet-5-5"
    end
  end

  describe "API keys" do
    test "each provider reads its own env var" do
      assert AI.api_key_var(:anthropic) == "ANTHROPIC_API_KEY"
      assert AI.api_key_var(:openai) == "OPENAI_API_KEY"
      assert AI.api_key_var(:openrouter) == "OPENROUTER_API_KEY"
    end

    test "a configured key counts as set; a blank one doesn't" do
      on_exit(fn -> Application.delete_env(:daily_output, :openai_api_key) end)

      Application.put_env(:daily_output, :openai_api_key, "sk-test")
      assert AI.api_key_set?(:openai)

      Application.put_env(:daily_output, :openai_api_key, "")
      refute AI.api_key_set?(:openai)
    end
  end

  defp req_response(message, usage, object \\ nil) do
    %ReqLLM.Response{
      id: "resp_test",
      context: ReqLLM.Context.new([]),
      message: message,
      model: "claude-sonnet-5-5",
      usage: usage,
      object: object
    }
  end

  describe "anthropic_shape/2" do
    test "maps text and usage, keeping reasoning tokens and total cost" do
      response =
        req_response(ReqLLM.Context.assistant("Hoi zäme!"), %{
          input_tokens: 10,
          output_tokens: 4,
          reasoning_tokens: 3,
          cached_tokens: 2,
          cache_creation_tokens: 1,
          total_cost: 0.0042
        })

      shaped = AI.anthropic_shape(response, "fallback")

      assert AI.text_content(shaped) == "Hoi zäme!"
      assert shaped["model"] == "claude-sonnet-5-5"

      assert shaped["usage"] == %{
               "input_tokens" => 10,
               "output_tokens" => 4,
               "reasoning_tokens" => 3,
               "cache_read_input_tokens" => 2,
               "cache_creation_input_tokens" => 1,
               "total_cost" => 0.0042
             }
    end

    test "missing usage fields default to 0 and the cost to nil" do
      response = %{req_response(ReqLLM.Context.assistant("x"), %{}) | model: nil}
      shaped = AI.anthropic_shape(response, "claude-sonnet-5-5")

      assert shaped["model"] == "claude-sonnet-5-5"
      assert shaped["usage"]["reasoning_tokens"] == 0
      assert shaped["usage"]["total_cost"] == nil
    end
  end

  describe "structured/1" do
    test "returns the decoded object" do
      response = req_response(ReqLLM.Context.assistant("{}"), %{}, %{"cards" => []})
      assert AI.structured(response) == {:ok, %{"cards" => []}}
    end

    test "a reply with no object is a parse miss, not an empty result" do
      response = req_response(ReqLLM.Context.assistant("Sorry, here you go: {"), %{})
      capture_log(fn -> assert AI.structured(response) == {:error, :unparsed} end)
    end
  end
end
