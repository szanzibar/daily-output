defmodule DailyOutput.AI.ConversationPartner do
  @moduledoc """
  The AI conversation partner. It never corrects the student, because each message gets its
  corrections separately. `wrap_up: true` makes this its last reply: warm, and no new question.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc "The partner's next reply to `messages` (`%{role, body}`, oldest first)."
  def respond(messages, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.fetch!(opts, :language_level)
    context = Keyword.get(opts, :about_you, "")
    profile = LanguageProfile.resolve(target)

    ending =
      if opts[:wrap_up],
        do: [
          "This is your last message: react warmly to what they just said and say goodbye. Don't ask a new question"
        ],
        else: ["Ask follow-up questions to keep the conversation going"]

    rules =
      ["Respond in #{profile.prompt_name} only"] ++
        profile.conventions ++
        [
          "Keep responses natural and conversational (2-3 sentences)",
          "Match the complexity to #{level} level — don't oversimplify, but be clear",
          "If they ask how to say something (e.g. \"How do you say X?\"), answer naturally",
          "If they ask about grammar or vocabulary, give a brief helpful answer",
          "Otherwise never correct, explain, or comment on their language — not even at the end. They see corrections separately, so just respond to what they said"
        ] ++
        ending ++
        ["Be warm and friendly, like a real conversation partner"]

    context_block = if context != "", do: "\nContext about the student: #{context}\n", else: ""

    system = """
    You are a friendly native #{profile.prompt_name} speaker having a casual conversation.
    The person you're talking to is a native #{native} speaker learning #{profile.prompt_name}, currently at CEFR level #{level}.
    #{context_block}
    Rules:
    #{Enum.map_join(rules, "\n", &"- #{&1}")}
    """

    with {:ok, text} <-
           AI.chat(
             [
               purpose: "conversation",
               system: system,
               messages: Enum.map(messages, &%{role: &1.role, content: &1.body}),
               max_tokens: 512
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      {:ok, String.trim(text)}
    end
  end
end
