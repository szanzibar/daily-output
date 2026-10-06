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
                       %{"input" => [_system, %{"content" => [%{"text" => content}]}]}}

      assert content =~ "Ich bin gelaufen."
      refute content =~ "Das war schön."
    end
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

  describe "due_today/1" do
    test "returns new cards up to the target" do
      for _ <- 1..3, do: new_card()
      assert length(Flashcards.due_today(10)) == 3
      assert length(Flashcards.due_today(2)) == 2
    end

    test "excludes deleted cards" do
      card = new_card()
      {:ok, _} = Flashcards.delete_card(card)
      assert Flashcards.due_today(10) == []
    end

    test "surfaces new cards even behind a full review backlog" do
      # More due review cards than the target: the old logic filled the whole batch with
      # them and starved new cards forever. Now new cards keep a reserved share.
      past = DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:second)

      for _ <- 1..20 do
        new_card() |> Card.schedule_changeset(%{state: "review", due_at: past}) |> Repo.update!()
      end

      for _ <- 1..5, do: new_card()

      batch = Flashcards.due_today(10)
      assert length(batch) == 10
      assert Enum.count(batch, &(&1.state == "new")) >= 1
    end
  end

  test "complete_day/1 records a day once" do
    Flashcards.complete_day(Clock.today())
    Flashcards.complete_day(Clock.today())

    assert Repo.aggregate(CompletedDay, :count) == 1
    assert Flashcards.completed_days() == MapSet.new([Clock.today()])
  end
end
