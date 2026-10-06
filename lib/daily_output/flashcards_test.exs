defmodule DailyOutput.FlashcardsTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Clock, Flashcards, Repo}
  alias DailyOutput.Flashcards.{Card, CompletedDay, Review}

  defp new_card(target \\ "Ich ging nach Hause.", native \\ "I went home.") do
    {:ok, card} =
      %Card{}
      |> Card.changeset(%{
        target_text: "#{target} #{System.unique_integer([:positive])}",
        native_text: native,
        language: "de",
        state: "new"
      })
      |> Repo.insert()

    card
  end

  describe "ingest/1" do
    test "skips when there is nothing substantive to drill (no AI call)" do
      activity = %{
        feedback: %{"annotated_text" => "Das [[haus||Haus||spelling||capital]] ist schön."},
        messages: [%{feedback: nil}, %{feedback: %{"annotated_text" => "Alles gut."}}]
      }

      assert {:ok, 0} = Flashcards.ingest(activity)
      assert {:ok, 0} = Flashcards.ingest(%{feedback: nil, messages: []})
      assert Flashcards.list_cards() == []
    end

    test "only the sentences with a mistake go to the AI" do
      activity = %{
        id: 1,
        feedback: %{"annotated_text" => "Das war schön. Ich [[habe||bin||verb||sein]] gelaufen."},
        messages: []
      }

      expect_ai(%{
        "cards" => [%{"target_text" => "Ich bin gelaufen.", "native_text" => "I walked."}]
      })

      assert {:ok, 1} = Flashcards.ingest(activity)

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"content" => [%{"text" => system}]},
                           %{"content" => [%{"text" => content}]}
                         ]
                       }}

      assert content =~ "Ich bin gelaufen."
      refute content =~ "Das war schön."
      assert system =~ "English translation that mirrors target_text's structure"
    end
  end

  test "suggest_pair/1 asks for a translation that mirrors the target's structure" do
    card =
      new_card("Solche Überraschungen geniesse ich sehr.", "I really enjoy surprises like that.")

    expect_ai(%{
      "cards" => [
        %{
          "target_text" => "Solche Überraschungen geniesse ich sehr.",
          "native_text" => "Such surprises I enjoy a lot."
        }
      ]
    })

    assert {:ok, %{"native_text" => "Such surprises I enjoy a lot."}} =
             Flashcards.suggest_pair(card)

    assert_received {:ai_request, %{"input" => [%{"content" => [%{"text" => system}]} | _]}}
    assert system =~ "mirrors its structure"
  end

  describe "review/2" do
    test "persists the rescheduled card and logs the review" do
      card = new_card()

      assert {:ok, updated} = Flashcards.review(card, :pass)
      assert updated.state == "review"
      refute is_nil(updated.due_at)

      reloaded = Repo.get(Card, card.id)
      assert reloaded.state == "review"
      assert Repo.aggregate(Review, :count) == 1
    end
  end

  describe "study_pool/1" do
    test "due reviews and new cards, oldest first, minus deleted and excepted ones" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      schedule = &(new_card() |> Card.schedule_changeset(&1) |> Repo.update!())

      due = schedule.(%{state: "review", due_at: DateTime.add(now, -60)})
      overdue = schedule.(%{state: "learning", due_at: DateTime.add(now, -3600)})
      _not_yet = schedule.(%{state: "review", due_at: DateTime.add(now, 3600)})
      new = new_card()
      newer = new_card()
      answered = new_card()
      {:ok, _} = Flashcards.delete_card(new_card())

      {due_cards, new_cards} = Flashcards.study_pool([answered.id])

      assert Enum.map(due_cards, & &1.id) == [overdue.id, due.id]
      assert Enum.map(new_cards, & &1.id) == [new.id, newer.id]
    end
  end

  test "reviewed_on/1 lists the cards reviewed that logical day" do
    card = new_card()
    {:ok, _} = Flashcards.review(card, :fail)
    {start, _} = Clock.day_range(Clock.today())

    Repo.insert!(%Review{
      card_id: new_card().id,
      result: true,
      inserted_at: DateTime.add(start, -60)
    })

    assert Flashcards.reviewed_on(Clock.today()) == [card.id]
  end

  test "complete_day/1 records a day once" do
    Flashcards.complete_day(Clock.today())
    Flashcards.complete_day(Clock.today())

    assert Repo.aggregate(CompletedDay, :count) == 1
    assert Flashcards.completed_days() == MapSet.new([Clock.today()])
  end
end
