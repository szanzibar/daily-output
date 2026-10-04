defmodule DailyOutput.PlannerTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Planner

  @dates Enum.map(0..299, &Date.add(~D[2026-01-01], &1))

  describe "activity_kind/2" do
    test "is the same for the same date" do
      for date <- @dates do
        assert Planner.activity_kind(["conversation"], date) ==
                 Planner.activity_kind(["conversation"], date)
      end
    end

    test "never journals two days in a row" do
      for date <- @dates, do: assert(Planner.activity_kind(["journal"], date) == "conversation")
    end

    test "journals about one day in three" do
      journals = Enum.count(@dates, &(Planner.activity_kind([], &1) == "journal"))
      assert journals in 70..130
    end
  end

  describe "angle/3" do
    test "is the same for the same date" do
      for date <- @dates, do: assert(Planner.angle([], nil, date) == Planner.angle([], nil, date))
    end

    test "skips the last 3 angles used" do
      for date <- @dates do
        recent = ["story", "debate", "plan", "thread"]
        refute Planner.angle(recent, nil, date) in Enum.take(recent, 3)
      end
    end

    test "prefers angles that draw out the focus" do
      # Only would-you-rather draws out gender.
      for date <- @dates, do: assert(Planner.angle([], "gender", date) == "would-you-rather")
    end

    test "falls back to any fresh angle when the fitting ones were just used" do
      for date <- @dates do
        refute Planner.angle(["would-you-rather"], "gender", date) == "would-you-rather"
      end
    end

    test "uses a variety of angles across days" do
      assert @dates |> Enum.map(&Planner.angle([], nil, &1)) |> Enum.uniq() |> length() == 8
    end
  end

  test "every angle has an instruction" do
    for date <- @dates do
      assert Planner.angle_instruction(Planner.angle([], nil, date)) =~ ~r/\w+/
    end
  end
end
