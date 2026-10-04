defmodule DailyOutput.StreakTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Streak

  @today ~D[2026-10-04]
  @passed %{activities: 1, cards?: true}
  @bonus %{activities: 2, cards?: true}

  # Facts for the days before today, oldest first.
  defp history(days) do
    days
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Map.new(fn {facts, ago} -> {Date.add(@today, -ago), facts} end)
  end

  test "no history" do
    assert Streak.compute(%{}, @today) == %{
             count: 0,
             freezes_available: 0,
             today_status: :pending
           }
  end

  test "an open day keeps the streak without adding to it" do
    assert %{count: 2, today_status: :pending} =
             Streak.compute(history([@passed, @passed]), @today)
  end

  test "passing today adds to the streak" do
    days = Map.put(history([@passed]), @today, @passed)
    assert %{count: 2, today_status: :passed} = Streak.compute(days, @today)
  end

  test "a day needs both an activity and the cards" do
    days = history([@passed, %{activities: 1, cards?: false}, %{activities: 0, cards?: true}])
    assert %{count: 0} = Streak.compute(days, @today)
  end

  test "a missed day without a freeze resets the streak" do
    assert %{count: 1} = Streak.compute(history([@passed, @passed, nil, @passed]), @today)
  end

  test "a bonus day banks a freeze" do
    assert %{count: 1, freezes_available: 1} = Streak.compute(history([@bonus]), @today)

    days = Map.put(history([@passed]), @today, @bonus)
    assert %{count: 2, freezes_available: 1, today_status: :bonus} = Streak.compute(days, @today)
  end

  test "freezes cap at 3" do
    assert %{count: 5, freezes_available: 3} =
             Streak.compute(history(List.duplicate(@bonus, 5)), @today)
  end

  test "a freeze bridges a missed day" do
    assert %{count: 2, freezes_available: 0} =
             Streak.compute(history([@bonus, nil, @passed]), @today)
  end

  test "one freeze doesn't bridge two missed days" do
    assert %{count: 1, freezes_available: 0} =
             Streak.compute(history([@bonus, nil, nil, @passed]), @today)
  end
end
