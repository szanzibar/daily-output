defmodule DailyOutput.FocusTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Focus

  @dates Enum.map(0..399, &Date.add(~D[2026-01-01], &1))

  test "nil on a cold start" do
    assert Focus.choose([], [], ~D[2026-10-04]) == nil
  end

  test "ignores spelling, punctuation, and other" do
    assert Focus.choose(~w(spelling spelling punctuation other), [], ~D[2026-10-04]) == nil
  end

  test "skips categories that were a recent focus" do
    for date <- @dates, do: assert(Focus.choose(~w(case case verb), ["case"], date) == "verb")
    assert Focus.choose(~w(case verb), ~w(case verb), ~D[2026-10-04]) == nil
  end

  test "is the same for the same date" do
    categories = ~w(case gender verb verb word-order)

    for date <- @dates do
      assert Focus.choose(categories, [], date) == Focus.choose(categories, [], date)
    end
  end

  test "weights categories by how often they show up" do
    picks = Enum.map(@dates, &Focus.choose(~w(case case case verb), [], &1))
    assert Enum.count(picks, &(&1 == "case")) in 250..350
    assert Enum.count(picks, &(&1 == "verb")) in 50..150
  end
end
