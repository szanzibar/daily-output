defmodule DailyOutput.Flashcards.SchedulerTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Scheduler

  @now ~U[2026-06-26 12:00:00Z]

  defp card(attrs),
    do: Enum.into(attrs, %{state: "new", ease: 2.5, reps: 0, interval_days: 0, lapses: 0})

  describe "a new card" do
    test "graduates to review with a 1-day interval when passed" do
      result = Scheduler.review(card(state: "new"), :pass, @now)

      assert result.state == "review"
      assert result.reps == 1
      assert result.interval_days == 1
      assert result.ease == 2.5
      assert result.due_at == DateTime.add(@now, 86_400, :second)
      assert result.last_reviewed_at == @now
    end

    test "drops to learning (no ease penalty) when failed" do
      result = Scheduler.review(card(state: "new"), :fail, @now)

      assert result.state == "learning"
      assert result.interval_days == 0
      assert result.ease == 2.5
      assert result.lapses == 0
      assert result.due_at == DateTime.add(@now, 60, :second)
    end
  end

  describe "a review card on pass" do
    test "uses the 6-day second interval after first graduation" do
      result = Scheduler.review(card(state: "review", reps: 1, interval_days: 1), :pass, @now)

      assert result.interval_days == 6
      assert result.reps == 2
    end

    test "multiplies interval by ease afterwards" do
      result =
        Scheduler.review(card(state: "review", reps: 2, interval_days: 6, ease: 2.5), :pass, @now)

      assert result.interval_days == 15
      assert result.reps == 3
      assert result.due_at == DateTime.add(@now, 15 * 86_400, :second)
    end
  end

  describe "a review card on fail (lapse)" do
    test "goes to relearning, counts a lapse, and dents the ease" do
      result =
        Scheduler.review(
          card(state: "review", reps: 5, interval_days: 40, ease: 2.5),
          :fail,
          @now
        )

      assert result.state == "relearning"
      assert result.reps == 0
      assert result.interval_days == 0
      assert result.lapses == 1
      assert result.ease == 2.3
      assert result.due_at == DateTime.add(@now, 600, :second)
    end

    test "floors the ease at 1.3" do
      result = Scheduler.review(card(state: "review", ease: 1.4), :fail, @now)
      assert result.ease == 1.3
    end
  end

  test "a relearning card graduates back to review when passed" do
    result = Scheduler.review(card(state: "relearning", lapses: 2), :pass, @now)

    assert result.state == "review"
    assert result.interval_days == 1
    assert result.lapses == 2
  end
end
