defmodule DailyOutput.AI.SessionStarter do
  @moduledoc """
  Opens a session: the partner's first message for a conversation, or the prompt for a
  journal. It picks up from last time's `summary`, follows the day's angle, and sets things up
  so the focus grammar comes out naturally. Always exactly one opener, never a list.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc """
  `kind` is `"conversation"` or `"journal"`. Opts: the profile (`:target_language`,
  `:native_language`, `:language_level`, `:about_you`), `:summary` (nil on the first session),
  `:angle` (an instruction from `Planner.angle_instruction/1`), and `:focus` (the banner map).
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def start(kind, opts) do
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.get(opts, :language_level, "B2")
    profile = LanguageProfile.resolve(Keyword.fetch!(opts, :target_language))
    %{"title" => focus_title, "body" => focus_body} = Keyword.fetch!(opts, :focus)

    task =
      case kind do
        "conversation" ->
          "You're their conversation partner, a friendly native speaker. Write your first message of a casual chat: 1-3 short sentences in #{profile.prompt_name}, ending with one question that's easy to start answering."

        "journal" ->
          "Write one journal prompt in #{profile.prompt_name}: 1-2 short sentences that give them something concrete to write about for five minutes."
      end

    last_time =
      case opts[:summary] do
        nil ->
          "This is your first session together."

        summary ->
          "Last session: #{summary}\nNod to it if it fits the angle, but don't just repeat its topic."
      end

    about =
      if opts[:about_you] in [nil, ""], do: "", else: "\nAbout the student: #{opts[:about_you]}\n"

    system = """
    You open today's practice session for a native #{native} speaker learning #{profile.prompt_name} at CEFR level #{level}.

    #{task}

    Angle: #{Keyword.fetch!(opts, :angle)}
    #{last_time}
    Today's grammar focus is «#{focus_title}» (#{focus_body}). Set things up so a natural answer needs it, but never name, explain, or hint at the grammar.
    #{about}
    Use words a #{level} learner knows.#{if profile.conventions != [], do: "\n" <> LanguageProfile.conventions_block(profile)}

    Reply with only the #{if kind == "journal", do: "prompt", else: "message"} itself: no preamble, quotes, or translation.
    """

    with {:ok, client} <- AI.client(),
         {:ok, response} <-
           AI.chat(
             client,
             [
               system: system,
               messages: [%{role: "user", content: "Start today's #{kind}."}],
               purpose: "starter",
               max_tokens: 2048
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      normalize(AI.text_content(response))
    end
  end

  @doc false
  def normalize(text) do
    case String.trim(text) do
      "" -> {:error, :unparsed}
      opener -> {:ok, opener}
    end
  end
end
