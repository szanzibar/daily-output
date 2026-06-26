defmodule DailyOutput.Flashcards.Scheduler do
  @moduledoc """
  Spaced-repetition scheduling — SM-2 adapted to **binary** pass/fail grading.

  This is a pure function with no DB and no AI, purely so the math is easy to test.
  The result it returns is persisted by `DailyOutput.Flashcards.review/2`, so the
  next-appearance time lives durably in `flashcards.due_at` — nothing here is ephemeral.

  States: `new` (never studied), `review` (graduated, scheduled in days),
  `learning` (a new card that was just missed) and `relearning` (a graduated card
  that lapsed). Missed cards get a short minutes-away `due_at` so they also resurface
  in the same sitting (the study session additionally re-queues them in memory).

  Intervals follow SM-2: first graduation = 1 day, then 6 days, then `interval * ease`.
  `ease` starts at 2.5, is unchanged on a pass (SM-2 quality ≈ 4), and drops by
  #{0.20} on a lapse (floored at #{1.3}). Ease and lapses only change when a *graduated*
  card is missed — fumbling a brand-new card shouldn't permanently penalize it.
  """

  @min_ease 1.3
  @lapse_penalty 0.20
  @graduating_interval 1
  @second_interval 6
  @again_minutes 1
  @relearn_minutes 10

  @doc """
  Computes the new SR fields for `card` given the `:pass`/`:fail` result.

  `card` is anything with the SR fields (a `Card` struct or a plain map). Returns an
  atom-keyed map of the changed fields, ready for `Card.schedule_changeset/2`.
  """
  def review(card, result, now \\ nil) do
    now = (now || DateTime.utc_now()) |> DateTime.truncate(:second)
    do_review(card, result, now)
  end

  defp do_review(card, :pass, now) do
    ease = ease(card)

    case state(card) do
      "review" ->
        reps = reps(card) + 1
        interval = next_review_interval(reps, interval(card), ease)
        graduate(reps, interval, ease, lapses(card), now)

      _new_or_learning ->
        # First successful study (or a relearn) graduates the card.
        graduate(reps(card) + 1, @graduating_interval, ease, lapses(card), now)
    end
  end

  defp do_review(card, :fail, now) do
    if state(card) == "review" do
      # A graduated card lapsed: count it, dent the ease, and send it to relearning.
      %{
        state: "relearning",
        reps: 0,
        interval_days: 0,
        ease: max(@min_ease, ease(card) - @lapse_penalty),
        lapses: lapses(card) + 1,
        due_at: add_minutes(now, @relearn_minutes),
        last_reviewed_at: now
      }
    else
      # Missing a new/learning/relearning card just restarts the learning step; no
      # ease penalty for a card you haven't learned yet.
      %{
        state: if(state(card) == "relearning", do: "relearning", else: "learning"),
        reps: 0,
        interval_days: 0,
        ease: ease(card),
        lapses: lapses(card),
        due_at: add_minutes(now, @again_minutes),
        last_reviewed_at: now
      }
    end
  end

  defp graduate(reps, interval, ease, lapses, now) do
    %{
      state: "review",
      reps: reps,
      interval_days: interval,
      ease: ease,
      lapses: lapses,
      due_at: add_days(now, interval),
      last_reviewed_at: now
    }
  end

  # SM-2 interval ladder by repetition number: n=1 (graduation) → n=2 = 6 days →
  # n>2 = interval * ease. `reps` here is the new (post-increment) repetition number.
  defp next_review_interval(reps, interval, ease) do
    if reps <= 2, do: @second_interval, else: max(1, round(interval * ease))
  end

  defp state(card), do: Map.get(card, :state) || "new"
  defp ease(card), do: Map.get(card, :ease) || 2.5
  defp reps(card), do: Map.get(card, :reps) || 0
  defp interval(card), do: Map.get(card, :interval_days) || 0
  defp lapses(card), do: Map.get(card, :lapses) || 0

  defp add_days(now, days), do: DateTime.add(now, days * 86_400, :second)
  defp add_minutes(now, minutes), do: DateTime.add(now, minutes * 60, :second)
end
