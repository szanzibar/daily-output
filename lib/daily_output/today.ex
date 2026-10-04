defmodule DailyOutput.Today do
  @moduledoc """
  `Today` decides what you do next. Pages ask `next_step/0` and render the answer, so
  reordering the flow is a one-line change to `@flow`.

  The first call of the day creates the main activity, with its kind, focus category, and
  angle picked from your history. Once the day passes, `start_bonus/0` adds the other kind,
  and `next_step/0` returns it until it's done. Nothing here calls the AI, so it's instant.
  """

  alias DailyOutput.{Activities, Clock, Flashcards, Focus, Planner, Streak}
  alias DailyOutput.Activities.Activity

  @flow [:activity, :cards]

  @journal_minutes 5
  @user_messages 5
  @cards 20

  # How far back the pickers look, and how long a focus category rests after use.
  @lookback_days 14
  @focus_rest_days 2

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

  # Cards count as done when nothing is due, because a new user has no cards yet. The row
  # still gets written, so the history stays derivable. Cards from an activity finished
  # seconds ago may still be generating; they join the next session. Known and accepted.
  defp step(:cards, _activities, today) do
    cond do
      today in Flashcards.completed_days() ->
        nil

      Flashcards.due_today(@cards) != [] ->
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

    resting =
      for %{date: date, focus: %{"category" => category}} <- recent,
          category,
          Date.diff(today, date) <= @focus_rest_days,
          do: category

    category = Focus.choose(Activities.correction_categories(recent), resting, today)

    Activities.create(%{
      kind: Planner.activity_kind(kinds, today),
      angle: Planner.angle(Enum.map(recent, & &1.angle), category, today),
      focus: %{"category" => category}
    })
  end

  @doc """
  Starts the bonus: the other kind of activity, with today's focus and a fresh angle. Only
  once the day has passed with one activity; returns `nil` otherwise.
  """
  def start_bonus do
    with %{today_status: :passed} <- streak(),
         [main] <- Activities.today() do
      today = Clock.today()
      recent_angles = Enum.map(Activities.recent(@lookback_days), & &1.angle)

      Activities.create(%{
        kind: if(main.kind == "journal", do: "conversation", else: "journal"),
        angle: Planner.angle(recent_angles, main.focus["category"], today),
        focus: main.focus
      })
    else
      _ -> nil
    end
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

  @doc "Today's card session: up to #{@cards} due cards."
  def card_queue, do: Flashcards.due_today(@cards)

  @doc "Marks today's card session done."
  def finish_cards, do: Flashcards.complete_day(Clock.today())

  @doc "When a journal's Finish button appears. Wall clock from the start, so a refresh keeps it."
  def journal_finish_at(%Activity{inserted_at: started}),
    do: DateTime.add(started, @journal_minutes, :minute)

  @doc "A conversation ends after your #{@user_messages}th message."
  def conversation_over?(%Activity{messages: messages}),
    do: Enum.count(messages, &(&1.role == "user")) >= @user_messages
end
