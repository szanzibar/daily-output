defmodule DailyOutput.Activities do
  @moduledoc """
  Conversations and journal entries, in one table. An activity belongs to the logical day it
  was created on, so day queries match on `date`.

  `complete/3` is the one way an activity finishes, so it's where flashcards get made.
  Activities come with their messages preloaded, oldest first.
  """

  import Ecto.Query
  require Logger

  alias DailyOutput.{Clock, Flashcards, Markers, Repo, Stats}
  alias DailyOutput.Activities.{Activity, Message}

  # Tests ingest inline, so the cards land inside the test's sandbox before it ends.
  @ingest_inline Mix.env() == :test

  @doc "Creates an activity on today's logical date."
  def create(attrs) do
    %Activity{date: Clock.today()}
    |> Activity.changeset(attrs)
    |> Repo.insert!()
    |> Repo.preload(:messages)
  end

  def get!(id), do: Activity |> Repo.get!(id) |> Repo.preload(:messages)

  @doc "Today's activities, oldest first."
  def today do
    today = Clock.today()
    Repo.all(from a in Activity, where: a.date == ^today, order_by: a.id, preload: :messages)
  end

  @doc "Activities from the last `days` days plus today, newest first."
  def recent(days) do
    since = Date.add(Clock.today(), -days)

    Repo.all(
      from a in Activity,
        where: a.date >= ^since,
        order_by: [desc: a.date, desc: a.id],
        preload: :messages
    )
  end

  @doc "Completed activities, newest first, without messages."
  def completed do
    Repo.all(
      from a in Activity,
        where: not is_nil(a.completed_at),
        order_by: [desc: a.date, desc: a.id]
    )
  end

  @doc """
  Every correction in `activities`, from the journal feedback and each message's, as
  `Markers.parse/1` maps, in the order the activities come.
  """
  def corrections(activities) do
    for activity <- activities,
        %{"annotated_text" => annotated} <- [
          activity.feedback | Enum.map(activity.messages, & &1.feedback)
        ],
        correction <- Markers.parse(annotated),
        do: correction
  end

  def add_message(%Activity{} = activity, role, body) do
    %Message{}
    |> Message.changeset(%{activity_id: activity.id, role: role, body: body})
    |> Repo.insert!()
  end

  def save_message_feedback(%Message{} = message, feedback) do
    message |> Message.changeset(%{feedback: feedback}) |> Repo.update!()
  end

  def update(%Activity{} = activity, attrs) do
    activity |> Activity.changeset(attrs) |> Repo.update!()
  end

  @doc """
  Finishes `activity` with its review and builds flashcards from its corrections in the
  background. Returns the activity reloaded with its messages.
  """
  def complete(%Activity{} = activity, feedback, summary) do
    activity
    |> Activity.changeset(%{
      feedback: feedback,
      summary: summary,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    completed = get!(activity.id)

    ingest = fn ->
      # A failed batch loses this activity's cards. Known and accepted.
      with {:error, reason} <- Flashcards.ingest(completed) do
        Logger.warning("Flashcards for activity #{completed.id} failed: #{inspect(reason)}")
      end
    end

    if @ingest_inline, do: ingest.(), else: Task.start(ingest)
    completed
  end

  @doc """
  Did you stop repeating a mistake once it was flagged? Pure, from the user messages'
  corrections:

    * `resolved_categories`: flagged in one message, then never again
    * `repeated_categories`: flagged in two or more messages
    * `early_rate` / `late_rate`: corrections per 100 words in the first vs. second half
  """
  def mistake_analysis(messages) do
    per_message =
      for %{role: "user"} = msg <- messages do
        text = (msg.feedback && msg.feedback["annotated_text"]) || msg.body
        %{categories: Enum.map(Markers.parse(text), & &1.category), words: Stats.word_count(text)}
      end

    n = length(per_message)

    # A category repeated within one message still counts once for "across messages".
    category_messages =
      per_message
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {%{categories: cats}, idx}, acc ->
        Enum.reduce(Enum.uniq(cats), acc, fn cat, acc2 ->
          Map.update(acc2, cat, [idx], &[idx | &1])
        end)
      end)

    resolved =
      for {cat, idxs} <- category_messages,
          length(idxs) == 1 and hd(idxs) < n - 1,
          do: cat

    repeated = for {cat, idxs} <- category_messages, length(idxs) >= 2, do: cat

    {early, late} = Enum.split(per_message, div(n, 2))

    %{
      "resolved_categories" => Enum.sort(resolved),
      "repeated_categories" => Enum.sort(repeated),
      "early_rate" => half_rate(early),
      "late_rate" => half_rate(late)
    }
  end

  defp half_rate(per_message) do
    words = per_message |> Enum.map(& &1.words) |> Enum.sum()
    corrections = per_message |> Enum.map(&length(&1.categories)) |> Enum.sum()
    if words == 0, do: nil, else: Float.round(corrections * 100 / words, 1)
  end
end
