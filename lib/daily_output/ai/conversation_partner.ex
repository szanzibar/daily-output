defmodule DailyOutput.AI.ConversationPartner do
  @moduledoc """
  AI conversation partner for role-play practice.
  """

  alias DailyOutput.AI

  def respond(messages, opts) do
    _target = Keyword.fetch!(opts, :target_language)
    native = Keyword.fetch!(opts, :native_language)
    level = Keyword.get(opts, :language_level, "B2")
    context = Keyword.get(opts, :prompt_context, "")

    context_block =
      if context != "" do
        "\nContext about the student: #{context}\n"
      else
        ""
      end

    system = """
    You are a friendly native Swiss German speaker (Schweizer Hochdeutsch) having a casual conversation.
    The person you're talking to is a #{native} speaker at CEFR level #{level}.
    #{context_block}
    Rules:
    - Respond in Swiss Standard German (Schweizer Hochdeutsch) only
    - Never use ß — always use ss
    - Use Swiss terms naturally (Velo, Poulet, Natel, Trottoir, parkieren, etc.)
    - Keep responses natural and conversational (2-3 sentences)
    - Match the complexity to #{level} level — don't oversimplify, but be clear
    - If they ask how to say something ("Wie sagt man X?"), answer naturally
    - If they ask about grammar or vocabulary, give a brief helpful answer
    - Otherwise do NOT correct their errors — just respond naturally
    - Ask follow-up questions to keep the conversation going
    - Be warm and friendly, like a real conversation partner
    """

    api_messages =
      Enum.map(messages, fn msg ->
        %{role: msg.role, content: msg.body}
      end)

    with {:ok, client} <- AI.client() do
      case Anthropix.chat(client,
             model: AI.model(),
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
