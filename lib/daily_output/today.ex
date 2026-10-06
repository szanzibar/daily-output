defmodule DailyOutput.Today do
  @moduledoc """
  `Today` decides what you do next. Pages ask `next_step/0` and render the answer, so
  reordering the flow is a one-line change to `@flow`.

  The first call of the day creates the main activity, with its kind, focus category, and
  angle picked from your history. Once the day passes, `start_bonus/0` adds the other kind,
  and `next_step/0` returns it until it's done. `next_step/0` never calls the AI, so it's
  instant.

  `prepare/1`, `correct_message/1`, `reply/1`, and `finish/1` call the AI, so pages run them
  async. Each returns `{:ok, _}` or `{:error, reason}`, and they read the activity fresh, so a
  stale struct is fine.
  """

  alias DailyOutput.{Activities, Clock, Flashcards, Focus, Planner, Settings, Streak}
  alias DailyOutput.Activities.{Activity, Message}
  alias DailyOutput.AI.{ConversationPartner, FocusWriter, Proofreader, SessionStarter}

  @flow [:activity, :cards]

  @journal_minutes 5
  @user_messages 5
  @cards 20

  # How far back the pickers look, and how long a focus category rests after use.
  @lookback_days 14
  @focus_rest_days 2
  # How many recent mistakes the focus banner is written from.
  @focus_mistakes 8

  @doc "`{:activity, activity}`, `:cards`, or `:done`."
  def next_step do
    today = Clock.today()
    activities = Activities.today()
    Enum.find_value(@flow, :done, &step(&1, activities, today))
  end

  defp step(:activity, [], today), do: {:activity, create_main(today)}

  defp step(:activity, activities, _today) do
    if activity = Enum.find(activities, &is_nil(&1.completed_at)), do: {:activity, activity}
  end

  # Cards are done after `@cards` answers, or when nothing unanswered is due, because a new
  # user has no cards yet. The row latches it, since what was due can't be derived later.
  # Cards from an activity finished seconds ago may still be generating; they join the next
  # session. Known and accepted.
  defp step(:cards, _activities, today) do
    cond do
      today in Flashcards.completed_days() ->
        nil

      match?({_answered, [_ | _]}, card_session()) ->
        :cards

      true ->
        Flashcards.complete_day(today)
        nil
    end
  end

  defp create_main(today) do
    recent = Activities.recent(@lookback_days)

    # Newest first within each day too, so a day's first activity is the last in its chunk.
    kinds = recent |> Enum.chunk_by(& &1.date) |> Enum.map(&List.last(&1).kind)
    create(Planner.activity_kind(kinds, today), recent, today)
  end

  @doc """
  Starts the bonus: the other kind of activity, with its own focus, because today's already
  had its turn. Only once the day has passed with one activity; returns `nil` otherwise.
  """
  def start_bonus do
    with %{today_status: :passed} <- streak(),
         [main] <- Activities.today() do
      kind = if main.kind == "journal", do: "conversation", else: "journal"
      create(kind, Activities.recent(@lookback_days), Clock.today())
    else
      _ -> nil
    end
  end

  # The focus comes from recent mistakes outside the resting categories, and the angle fits it.
  defp create(kind, recent, today) do
    categories = Enum.map(Activities.corrections(recent), & &1.category)
    category = Focus.choose(categories, resting(recent, today), today)

    Activities.create(%{
      kind: kind,
      angle: Planner.angle(Enum.map(recent, & &1.angle), category, today),
      focus: %{"category" => category}
    })
  end

  # Today's focus rests too, so the bonus never repeats it.
  defp resting(recent, today) do
    for %{date: date, focus: %{"category" => category}} <- recent,
        category,
        Date.diff(today, date) <= @focus_rest_days,
        do: category
  end

  @doc "The streak, from completed activities and card days. Today passed unless `:pending`."
  def streak do
    card_days = Flashcards.completed_days()
    activity_counts = Enum.frequencies_by(Activities.completed(), & &1.date)

    days =
      Map.new(Enum.uniq(Map.keys(activity_counts) ++ MapSet.to_list(card_days)), fn date ->
        {date, %{activities: Map.get(activity_counts, date, 0), cards?: date in card_days}}
      end)

    Streak.compute(days, Clock.today())
  end

  @doc """
  Writes what an activity opens with: the focus banner, then the prompt (a journal's prompt
  or the partner's first message). Each is saved as soon as it's written, so a retry only
  redoes what failed.
  """
  def prepare(%Activity{} = activity) do
    activity = Activities.get!(activity.id)

    with {:ok, activity} <- write_focus(activity) do
      write_prompt(activity)
    end
  end

  # Written already when only the prompt failed last time.
  defp write_focus(%Activity{focus: %{"title" => _}} = activity), do: {:ok, activity}

  defp write_focus(%Activity{focus: %{"category" => category}} = activity) do
    recent = Activities.recent(@lookback_days)

    mistakes =
      recent
      |> Activities.corrections()
      |> Enum.filter(&(&1.category == category))
      |> Enum.take(@focus_mistakes)

    # Without a category the AI picks one, so it skips the resting ones too.
    opts = profile() ++ [resting: resting(recent, activity.date)]

    with {:ok, focus} <- FocusWriter.write(category, mistakes, opts) do
      {:ok, Activities.update(activity, %{focus: focus})}
    end
  end

  defp write_prompt(%Activity{prompt: nil} = activity) do
    opts =
      profile() ++
        [
          summary: Enum.find_value(Activities.completed(), & &1.summary),
          angle: Planner.angle_instruction(activity.angle),
          focus: activity.focus
        ]

    with {:ok, prompt} <- SessionStarter.start(activity.kind, opts) do
      {:ok, Activities.update(activity, %{prompt: prompt})}
    end
  end

  defp write_prompt(activity), do: {:ok, activity}

  @doc "Corrects one of your messages and saves the corrections on it."
  def correct_message(%Message{} = message) do
    before =
      message.activity_id
      |> Activities.get!()
      |> history()
      |> Enum.take_while(&(Map.get(&1, :id) != message.id))

    with {:ok, feedback} <-
           Proofreader.proofread_message(message.body, profile() ++ [context_messages: before]) do
      {:ok, Activities.save_message_feedback(message, feedback)}
    end
  end

  @doc """
  The partner's reply to the conversation so far, saved as its message. The reply to your
  #{@user_messages}th message wraps the conversation up.
  """
  def reply(%Activity{} = activity) do
    activity = Activities.get!(activity.id)
    opts = [wrap_up: conversation_over?(activity)] ++ profile()

    with {:ok, text} <- ConversationPartner.respond(history(activity), opts) do
      {:ok, Activities.add_message(activity, "assistant", text)}
    end
  end

  @doc """
  Reviews the activity and completes it. A journal gets proofread; a conversation, already
  corrected message by message, gets its improvement panel. Both get the focus graded and a
  summary for next time.

  A refresh can kill a message's correction mid-flight, so any message still without one
  gets corrected first, and the grade and the cards never miss it.
  """
  def finish(%Activity{} = activity) do
    activity = Activities.get!(activity.id)
    uncorrected = for %Message{role: "user", feedback: nil} = m <- activity.messages, do: m

    with :ok <- correct_all(uncorrected),
         activity = Activities.get!(activity.id),
         {:ok, review} <- review(activity, profile() ++ [focus: activity.focus]) do
      {summary, feedback} = Map.pop!(review, "summary")
      {:ok, Activities.complete(activity, feedback, summary)}
    end
  end

  defp correct_all([]), do: :ok

  defp correct_all([message | rest]) do
    with {:ok, _} <- correct_message(message), do: correct_all(rest)
  end

  defp review(%Activity{kind: "journal"} = activity, opts),
    do: Proofreader.proofread(activity.body, opts)

  defp review(%Activity{kind: "conversation"} = activity, opts) do
    with {:ok, review} <- Proofreader.assess_conversation(history(activity), opts) do
      {:ok, Map.put(review, "improvement", Activities.mistake_analysis(activity.messages))}
    end
  end

  # The opener lives in `prompt`, so it's the conversation's first turn.
  defp history(activity), do: [%{role: "assistant", body: activity.prompt} | activity.messages]

  defp profile do
    config = Settings.get_config()

    [
      target_language: config.target_language,
      native_language: config.native_language,
      language_level: config.language_level,
      about_you: config.about_you
    ]
  end

  @doc """
  Today's card session as `{answered, queue}`: how many cards you've answered today, and the
  due cards you haven't, up to #{@cards} in all. Both come from today's reviews, so a refresh
  resumes with the same cards in the same order.
  """
  def card_session do
    today = Clock.today()
    answered = Flashcards.reviewed_on(today)
    {due, new} = Flashcards.study_pool(answered)
    # When both pools exceed their share, a refresh can swap a card. Known and accepted.
    {length(answered), Planner.cards(due, new, @cards - length(answered), today)}
  end

  @doc """
  Practice once the day is done, as `{still_due, queue}`: how many due cards you haven't
  answered today, and up to #{@cards} of them. It never touches the streak.
  """
  def extra_practice do
    today = Clock.today()
    {due, new} = Flashcards.study_pool(Flashcards.reviewed_on(today))
    {length(due) + length(new), Planner.cards(due, new, @cards, today)}
  end

  @doc """
  Seconds until a journal's Finish button appears, from the active time logged on the page
  today. Only one journal happens per day, so the day's journal time is this journal's.
  """
  def journal_seconds_left(logged_seconds), do: max(@journal_minutes * 60 - logged_seconds, 0)

  @doc "How many messages you write in a conversation."
  def message_limit, do: @user_messages

  @doc "A conversation ends after your #{@user_messages}th message."
  def conversation_over?(%Activity{messages: messages}),
    do: Enum.count(messages, &(&1.role == "user")) >= @user_messages
end
