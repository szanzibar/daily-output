defmodule DailyOutput.TodayTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Activities, Clock, Today}
  alias DailyOutput.Activities.{Activity, Message}
  alias DailyOutput.Flashcards.{Card, CompletedDay}

  @card %Card{target_text: "Ich ging nach Hause.", native_text: "I went home.", language: "de"}

  describe "next_step/0" do
    test "a fresh day creates the main activity" do
      assert {:activity, activity} = Today.next_step()
      assert activity.date == Clock.today()
      assert activity.kind in ~w(conversation journal)
      assert is_binary(activity.angle)
      # Cold start: no mistakes yet, so the category is left for the AI to pick.
      assert activity.focus == %{"category" => nil}
    end

    test "resuming mid-day returns the same activity" do
      {:activity, first} = Today.next_step()
      {:activity, again} = Today.next_step()

      assert again.id == first.id
      assert length(Activities.today()) == 1
    end

    test "yesterday's unfinished activity is abandoned for a fresh one" do
      yesterday = Activities.create(%{kind: "journal", date: Date.add(Clock.today(), -1)})

      {:activity, activity} = Today.next_step()

      assert activity.id != yesterday.id
      assert activity.date == Clock.today()
      # Never two journal days in a row.
      assert activity.kind == "conversation"
    end

    test "the focus comes from recent mistakes and rests after use" do
      Activities.create(%{
        kind: "conversation",
        date: Date.add(Clock.today(), -1),
        focus: %{"category" => "case"},
        feedback: %{"annotations" => Enum.map(~w(case case verb), &%{"category" => &1})},
        completed_at: DateTime.utc_now()
      })

      assert {:activity, %{focus: %{"category" => "verb"}}} = Today.next_step()
    end

    test "a completed activity moves on to cards" do
      Repo.insert!(@card)
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)

      assert Today.next_step() == :cards
    end

    test "with nothing due the cards are skipped, and the day is recorded" do
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)

      assert Today.next_step() == :done
      assert Repo.get_by(CompletedDay, day: Clock.today())
    end

    test "finishing the cards is done" do
      Repo.insert!(@card)
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)
      Today.finish_cards()

      assert Today.next_step() == :done
      assert Today.streak().today_status == :passed
    end

    test "the bonus is the other kind with the same focus, then done again" do
      {:activity, main} = Today.next_step()
      Activities.complete(main, %{}, nil)
      assert Today.next_step() == :done

      bonus = Today.start_bonus()

      assert bonus.kind != main.kind
      assert bonus.focus == main.focus
      assert bonus.angle != main.angle
      assert {:activity, %{id: id}} = Today.next_step()
      assert id == bonus.id

      Activities.complete(bonus, %{}, nil)
      assert Today.next_step() == :done
      assert %{today_status: :bonus, freezes_available: 1} = Today.streak()
    end

    test "the bonus needs a passed day, and there's only one" do
      {:activity, main} = Today.next_step()
      assert Today.start_bonus() == nil

      Activities.complete(main, %{}, nil)
      Today.next_step()
      assert Today.start_bonus()
      assert Today.start_bonus() == nil
    end
  end

  test "streak/0 counts passed days from completed activities and card days" do
    yesterday = Date.add(Clock.today(), -1)
    Activities.create(%{kind: "journal", date: yesterday, completed_at: DateTime.utc_now()})
    Repo.insert!(%CompletedDay{day: yesterday})

    assert Today.streak() == %{count: 1, freezes_available: 0, today_status: :pending}
  end

  test "journal_finish_at/1 is 5 minutes after the start" do
    activity = %Activity{inserted_at: ~U[2026-10-04 10:00:00Z]}
    assert Today.journal_finish_at(activity) == ~U[2026-10-04 10:05:00Z]
  end

  test "conversation_over?/1 after the 5th user message" do
    four = List.duplicate(%Message{role: "user"}, 4) ++ [%Message{role: "assistant"}]

    refute Today.conversation_over?(%Activity{messages: four})
    assert Today.conversation_over?(%Activity{messages: [%Message{role: "user"} | four]})
  end
end
