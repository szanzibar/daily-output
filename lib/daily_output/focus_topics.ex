defmodule DailyOutput.FocusTopics do
  @moduledoc """
  Context for managing focus topics and daily challenge status.
  """

  import Ecto.Query
  alias DailyOutput.Clock
  alias DailyOutput.Repo
  alias DailyOutput.FocusTopics.FocusTopic
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Conversations.Conversation

  # ── CRUD ─────────────────────────────────────────────

  def list_active_topics do
    FocusTopic
    |> where([t], is_nil(t.mastered_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_all_topics do
    FocusTopic
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def get_topic!(id), do: Repo.get!(FocusTopic, id)

  def create_topic(attrs) do
    source_text = attrs[:source_text] || attrs["source_text"]

    if source_text && source_text != "" do
      existing =
        Repo.one(
          from(t in FocusTopic,
            where: t.source_text == ^source_text and is_nil(t.mastered_at),
            limit: 1
          )
        )

      if existing do
        {:error, :duplicate}
      else
        %FocusTopic{}
        |> FocusTopic.changeset(attrs)
        |> Repo.insert()
      end
    else
      %FocusTopic{}
      |> FocusTopic.changeset(attrs)
      |> Repo.insert()
    end
  end

  def master_topic(%FocusTopic{} = topic) do
    topic
    |> Ecto.Changeset.change(%{mastered_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  def delete_topic(%FocusTopic{} = topic) do
    Repo.delete(topic)
  end

  @doc "Returns a MapSet of source_texts for active topics (used for duplicate detection on tip buttons)."
  def active_source_texts do
    FocusTopic
    |> where([t], is_nil(t.mastered_at))
    |> select([t], t.source_text)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def has_active_topics? do
    Repo.exists?(from(t in FocusTopic, where: is_nil(t.mastered_at)))
  end

  # ── Daily Challenge & Streak ─────────────────────────

  # You earn one streak freeze per N full days (both tasks), capped, so a missed day
  # doesn't reset a hard-won streak to zero.
  @full_days_per_freeze 5
  @max_freezes 3

  @doc """
  Today's challenge status. Entry/conversation complete = has feedback AND completed_at.
  This allows entries with feedback but unmet focus requirements to remain drafts.
  """
  def daily_challenge_status do
    {entry_done, convo_done} = day_completions(Clock.today())

    %{
      entry: if(entry_done, do: :complete, else: :none),
      conversation: if(convo_done, do: :complete, else: :none),
      all_done: entry_done and convo_done
    }
  end

  @doc "The tier reached on `date`: :full (both tasks), :partial (one), or :none."
  def day_status(date) do
    case day_completions(date) do
      {true, true} -> :full
      {false, false} -> :none
      _ -> :partial
    end
  end

  @doc "True when `date` counts toward the streak — at least one task done."
  def day_kept?(date), do: day_status(date) != :none

  @doc "Backwards-compatible check for a fully completed day (both tasks)."
  def day_completed?(date), do: day_status(date) == :full

  @doc "Count of consecutive kept days ending today (freeze-aware)."
  def current_streak, do: streak_info().count

  # Streak lengths worth celebrating, plus every further century.
  @streak_milestones [3, 7, 14, 30, 50, 100]

  @doc "True when a streak count is a milestone (worth a celebration)."
  def streak_milestone?(count) when is_integer(count),
    do: count in @streak_milestones or (count > 100 and rem(count, 100) == 0)

  def streak_milestone?(_), do: false

  @doc """
  Streak details with tiered days and streak freezes.

  A day counts if it's at least *partial* (one task done). Missed days are bridged by
  *freezes*: you earn one per #{@full_days_per_freeze} full days (capped at
  #{@max_freezes}), and each missed day bridged in your current run spends one. Today
  not being done yet never zeroes the streak — it just leaves it at risk.

  Returns `%{count, freezes_available, today_status}`.
  """
  def streak_info do
    entry_dates = completed_logical_dates(Entry)
    convo_dates = completed_logical_dates(Conversation)

    full_days = MapSet.intersection(entry_dates, convo_dates) |> MapSet.size()
    earned = min(@max_freezes, div(full_days, @full_days_per_freeze))
    kept = MapSet.union(entry_dates, convo_dates)

    today = Clock.today()
    start = if MapSet.member?(kept, today), do: today, else: Date.add(today, -1)

    {count, consumed} = walk_streak(start, kept, 0, earned, 0)

    %{
      count: count,
      freezes_available: max(0, earned - consumed),
      today_status: status_from(entry_dates, convo_dates, today)
    }
  end

  defp walk_streak(date, kept, count, budget, consumed) do
    if MapSet.member?(kept, date) do
      walk_streak(Date.add(date, -1), kept, count + 1, budget, consumed)
    else
      # A run of missed days only continues the streak if freezes can cover the whole
      # gap AND there's an earlier kept day to bridge to (don't spend freezes on the void).
      case measure_gap(date, kept, budget, 0) do
        {gap, next_kept} when not is_nil(next_kept) ->
          walk_streak(next_kept, kept, count, budget - gap, consumed + gap)

        _ ->
          {count, consumed}
      end
    end
  end

  defp measure_gap(date, kept, budget, gap) do
    cond do
      gap > budget -> {gap, nil}
      MapSet.member?(kept, date) -> {gap, date}
      true -> measure_gap(Date.add(date, -1), kept, budget, gap + 1)
    end
  end

  # {entry_done?, conversation_done?} for a single logical day.
  defp day_completions(date) do
    {start, stop} = Clock.day_range(date)
    {completed_exists?(Entry, start, stop), completed_exists?(Conversation, start, stop)}
  end

  defp completed_exists?(schema, start, stop) do
    Repo.exists?(
      from(r in schema,
        where:
          is_nil(r.deleted_at) and not is_nil(r.feedback) and not is_nil(r.completed_at) and
            r.inserted_at >= ^start and r.inserted_at < ^stop
      )
    )
  end

  # Set of logical dates with at least one completed record of `schema`.
  defp completed_logical_dates(schema) do
    from(r in schema,
      where: is_nil(r.deleted_at) and not is_nil(r.feedback) and not is_nil(r.completed_at),
      select: r.inserted_at
    )
    |> Repo.all()
    |> Enum.map(&Clock.to_logical_date/1)
    |> MapSet.new()
  end

  defp status_from(entry_dates, convo_dates, date) do
    entry? = MapSet.member?(entry_dates, date)
    convo? = MapSet.member?(convo_dates, date)

    cond do
      entry? and convo? -> :full
      entry? or convo? -> :partial
      true -> :none
    end
  end
end
