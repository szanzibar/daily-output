defmodule DailyOutput.AI.OpenRouterClient do
  @moduledoc """
  OpenRouter API client using Req.
  Translates Anthropix-style options to OpenAI-compatible format
  and normalizes responses back to match the Anthropix response shape.
  """

  require Logger

  @base_url "https://openrouter.ai/api/v1/chat/completions"

  @doc """
  Sends a chat request to OpenRouter.

  Accepts the same keyword options as `Anthropix.chat/2`:
    - `:model` - model ID (required)
    - `:system` - system prompt string
    - `:messages` - list of `%{role: String.t(), content: String.t()}`
    - `:max_tokens` - max response tokens
    - `:tools` - list of tool definitions (Anthropic format, auto-converted)
    - `:tool_choice` - tool choice specification (Anthropic format, auto-converted)

  Returns `{:ok, response}` matching Anthropix response format:
    - Text: `{:ok, %{"content" => [%{"type" => "text", "text" => "..."}]}}`
    - Tool use: `{:ok, %{"content" => [%{"type" => "tool_use", "name" => "...", "input" => %{}}]}}`
  """
  def chat(api_key, opts) do
    model = Keyword.fetch!(opts, :model)
    messages = build_messages(opts)
    max_tokens = Keyword.get(opts, :max_tokens, 1024)

    body =
      %{
        model: model,
        messages: messages,
        max_tokens: max_tokens
      }
      |> maybe_add_tools(opts)
      |> maybe_add_tool_choice(opts)

    req =
      Req.new(
        url: @base_url,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        json: body
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, normalize_response(body)}

      {:ok, %{status: status, body: body}} ->
        error_message = get_in(body, ["error", "message"]) || inspect(body)
        Logger.error("OpenRouter API error #{status}: #{error_message}")
        {:error, "OpenRouter API error #{status}: #{error_message}"}

      {:error, reason} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_messages(opts) do
    system = Keyword.get(opts, :system)
    messages = Keyword.get(opts, :messages, [])

    system_msgs =
      if system && system != "" do
        [%{role: "system", content: system}]
      else
        []
      end

    user_msgs =
      Enum.map(messages, fn msg ->
        %{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
      end)

    system_msgs ++ user_msgs
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        openai_tools =
          Enum.map(tools, fn tool ->
            %{
              type: "function",
              function: %{
                name: tool[:name] || tool["name"],
                description: tool[:description] || tool["description"],
                parameters: tool[:input_schema] || tool["input_schema"]
              }
            }
          end)

        Map.put(body, :tools, openai_tools)
    end
  end

  defp maybe_add_tool_choice(body, opts) do
    case Keyword.get(opts, :tool_choice) do
      nil ->
        body

      %{type: "tool", name: name} ->
        Map.put(body, :tool_choice, %{type: "function", function: %{name: name}})

      %{"type" => "tool", "name" => name} ->
        Map.put(body, :tool_choice, %{type: "function", function: %{name: name}})

      _ ->
        body
    end
  end

  defp normalize_response(%{"choices" => [choice | _]}) do
    message = choice["message"] || %{}
    tool_calls = message["tool_calls"]

    content =
      cond do
        is_list(tool_calls) && tool_calls != [] ->
          Enum.map(tool_calls, fn tc ->
            func = tc["function"] || %{}

            args =
              case func["arguments"] do
                args when is_binary(args) ->
                  case Jason.decode(args) do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                args when is_map(args) ->
                  args

                _ ->
                  %{}
              end

            %{
              "type" => "tool_use",
              "name" => func["name"],
              "input" => args
            }
          end)

        is_binary(message["content"]) ->
          [%{"type" => "text", "text" => message["content"]}]

        true ->
          [%{"type" => "text", "text" => ""}]
      end

    %{"content" => content}
  end

  defp normalize_response(unexpected) do
    Logger.error("Unexpected OpenRouter response shape: #{inspect(unexpected)}")
    %{"content" => [%{"type" => "text", "text" => ""}]}
  end
end
