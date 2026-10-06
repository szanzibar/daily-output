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

  describe "cards/4" do
    @due for id <- 1..30, do: %{id: id, state: "review"}
    @new for id <- 31..60, do: %{id: id, state: "new"}

    test "is the same for the same date, and differs across days" do
      today = Planner.cards(@due, @new, 20, ~D[2026-10-06])

      assert Planner.cards(@due, @new, 20, ~D[2026-10-06]) == today
      refute Planner.cards(@due, @new, 20, ~D[2026-10-07]) == today
    end

    test "answering cards never moves the rest" do
      due = Enum.take(@due, 6)
      new = Enum.take(@new, 4)
      [first, second | rest] = Planner.cards(due, new, 20, ~D[2026-10-06])

      assert Planner.cards(due -- [first, second], new -- [first, second], 18, ~D[2026-10-06]) ==
               rest
    end

    test "takes the oldest due reviews plus up to half new cards, mixed" do
      cards = Planner.cards(@due, @new, 20, ~D[2026-10-06])

      assert Enum.sort(Enum.map(cards, & &1.id)) == Enum.to_list(1..10) ++ Enum.to_list(31..40)
      refute Enum.take(cards, 10) |> Enum.all?(&(&1.state == "review"))
    end

    test "a short pool leaves its slack to the other" do
      assert length(Planner.cards(Enum.take(@due, 2), @new, 20, ~D[2026-10-06])) == 20
      assert length(Planner.cards(@due, Enum.take(@new, 2), 20, ~D[2026-10-06])) == 20
      assert length(Planner.cards([], Enum.take(@new, 3), 20, ~D[2026-10-06])) == 3
    end

    test "a new card still makes it into a one-card session" do
      assert [%{state: "new"}] = Planner.cards(@due, @new, 1, ~D[2026-10-06])
    end

    test "nothing when the session is already full" do
      assert Planner.cards(@due, @new, 0, ~D[2026-10-06]) == []
      assert Planner.cards(@due, @new, -3, ~D[2026-10-06]) == []
    end
  end

  test "every angle has an instruction" do
    for date <- @dates do
      assert Planner.angle_instruction(Planner.angle([], nil, date)) =~ ~r/\w+/
    end
  end
end
