defmodule DailyOutput.AITest do
  # Not async: the key tests set global app env.
  use DailyOutput.DataCase, async: false

  import ExUnit.CaptureLog

  alias DailyOutput.AI

  @schema %{
    "type" => "object",
    "properties" => %{"x" => %{"type" => "string"}},
    "required" => ["x"],
    "additionalProperties" => false
  }

  describe "spec_for/2" do
    test "direct routes to OpenAI's own API" do
      assert AI.spec_for("direct", "gpt-6.1-sol") == "openai:gpt-6.1-sol"
      assert AI.spec_for("direct", "gpt-6-luna") == "openai:gpt-6-luna"
    end

    test "openrouter routes to OpenRouter's slugs" do
      assert AI.spec_for("openrouter", "gpt-6.1-sol") == "openrouter:openai/gpt-6.1-sol"
      assert AI.spec_for("openrouter", "gpt-6-luna") == "openrouter:openai/gpt-6-luna"
    end
  end

  describe "API keys" do
    test "each provider reads its own env var" do
      assert AI.api_key_var(:anthropic) == "ANTHROPIC_API_KEY"
      assert AI.api_key_var(:openai) == "OPENAI_API_KEY"
      assert AI.api_key_var(:openrouter) == "OPENROUTER_API_KEY"
    end

    test "a configured key counts as set; a blank one doesn't" do
      on_exit(fn -> Application.delete_env(:daily_output, :openrouter_api_key) end)

      Application.put_env(:daily_output, :openrouter_api_key, "sk-test")
      assert AI.api_key_set?(:openrouter)

      Application.put_env(:daily_output, :openrouter_api_key, "")
      refute AI.api_key_set?(:openrouter)
    end
  end

  describe "chat/1" do
    test "returns the reply text and records the call's usage under its purpose" do
      expect_ai("Hoi zäme!")

      assert AI.chat(
               purpose: "starter",
               messages: [%{role: "user", content: "Hoi"}],
               max_tokens: 10
             ) ==
               {:ok, "Hoi zäme!"}

      assert [%{purpose: "starter", model: "gpt-6.1-sol", input_tokens: 100, output_tokens: 20}] =
               Repo.all(DailyOutput.Stats.ApiUsage)
    end
  end

  describe "reasoning effort" do
    test "each model gets its own effort, and the bench can override it" do
      for {model, effort, expected} <- [
            {"openai:gpt-6.1-sol", nil, "low"},
            {"openai:gpt-6-luna", nil, "medium"},
            {"openai:gpt-6-luna", :none, "none"}
          ] do
        expect_ai("Hoi")
        messages = [%{role: "user", content: "Hoi"}]

        assert {:ok, _} =
                 AI.chat(
                   model: model,
                   effort: effort,
                   messages: messages,
                   max_tokens: 10,
                   purpose: "test"
                 )

        assert_received {:ai_request, %{"reasoning" => %{"effort" => ^expected}}}
      end
    end

    test "OpenRouter gets the same effort, and json_schema for structured calls" do
      Application.put_env(:daily_output, :openrouter_api_key, "test")
      on_exit(fn -> Application.delete_env(:daily_output, :openrouter_api_key) end)
      test = self()

      # Only the request matters here, so the reply is an error.
      Req.Test.expect(DailyOutput.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:ai_request, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => %{"code" => 400}})
      end)

      AI.chat(
        purpose: "test",
        model: "openrouter:openai/gpt-6-luna",
        schema: @schema,
        messages: [%{role: "user", content: "Hoi"}],
        max_tokens: 10
      )

      assert_received {:ai_request,
                       %{
                         "reasoning_effort" => "medium",
                         "response_format" => %{"type" => "json_schema"}
                       }}
    end

    test "Anthropic turns effort into thinking, and structured calls use json_schema" do
      Application.put_env(:daily_output, :anthropic_api_key, "test")
      on_exit(fn -> Application.delete_env(:daily_output, :anthropic_api_key) end)
      test = self()

      for {effort, thinking, output_config} <- [
            {nil, %{"type" => "between_tools"}, nil},
            {:low, %{"type" => "adaptive", "display" => "summarized"}, %{"effort" => "low"}}
          ] do
        # Only the request matters here, so the reply is Anthropic's 400.
        Req.Test.expect(DailyOutput.AI, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:ai_request, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{"type" => "invalid_request_error", "message" => "bad request"}
          })
        end)

        AI.chat(
          purpose: "test",
          model: "anthropic:claude-sonnet-5-5",
          effort: effort,
          schema: @schema,
          messages: [%{role: "user", content: "Hoi"}],
          max_tokens: 10
        )

        assert_received {:ai_request,
                         %{"thinking" => ^thinking, "output_format" => %{"type" => "json_schema"}} =
                           body}

        assert body["output_config"] == output_config
      end
    end
  end

  defp req_response(message, usage, object \\ nil) do
    %ReqLLM.Response{
      id: "resp_test",
      context: ReqLLM.Context.new([]),
      message: message,
      model: "gpt-6.1-sol",
      usage: usage,
      object: object
    }
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
