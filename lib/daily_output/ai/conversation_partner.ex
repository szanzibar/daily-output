defmodule DailyOutput.AI.ConversationPartner do
  @moduledoc """
  AI conversation partner for role-play practice.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc """
  Opens a conversation about `topic` (given in any language) by producing the first
  message from the partner. Used when the student picks "let the AI start" instead of
  writing the opening line themselves.
  """
  def open(topic, opts) do
    instruction =
      "Start our conversation. Bring up this topic naturally and ask me an opening question about it: #{topic}"

    respond([%{role: "user", body: instruction}], opts)
  end

  def respond(messages, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")
    profile = LanguageProfile.resolve(target)

    rules =
      [
        "Respond in #{profile.prompt_name} only"
      ] ++
        profile.conventions ++
        [
          "Keep responses natural and conversational (2-3 sentences)",
          "Match the complexity to #{level} level — don't oversimplify, but be clear",
          "If they ask how to say something (\"Wie sagt man X?\"), answer naturally",
          "If they ask about grammar or vocabulary, give a brief helpful answer",
          "Otherwise do NOT correct their errors — just respond naturally",
          "Ask follow-up questions to keep the conversation going",
          "Be warm and friendly, like a real conversation partner"
        ]

    rules_block =
      rules
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    context_block =
      if context != "" do
        "\nContext about the student: #{context}\n"
      else
        ""
      end

    system = """
    You are a friendly native #{profile.prompt_name} speaker having a casual conversation.
    The person you're talking to is a #{native} speaker learning #{profile.prompt_name}, currently at CEFR level #{level}.
    #{context_block}
    Rules:
    #{rules_block}
    """

    api_messages =
      Enum.map(messages, fn msg ->
        %{role: msg.role, content: msg.body}
      end)

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             purpose: "conversation",
             system: system,
             messages: api_messages,
             max_tokens: 512
           ) do
        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          {:ok, String.trim(text)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
