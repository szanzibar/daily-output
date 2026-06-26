defmodule DailyOutput.FlashcardsTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Clock, Flashcards, Repo, Settings}
  alias DailyOutput.Flashcards.{Card, Review}

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

  defp set_target(n) do
    {:ok, config} = Settings.ensure_config()
    {:ok, _} = Settings.update_config(config, %{flashcards_per_day: n})
  end

  describe "ingest_correction/4" do
    test "skips when there is nothing to correct (no AI call)" do
      assert {:ok, 0} = Flashcards.ingest_correction(:message, 1, nil)

      assert {:ok, 0} =
               Flashcards.ingest_correction(:message, 1, %{"annotated_text" => "Alles gut."})
    end

    test "skips a correction that is only a capitalization fix (no AI call)" do
      feedback = %{
        "annotated_text" => "Das [[1:haus||Haus]] ist schön.",
        "annotations" => [%{"id" => 1, "category" => "spelling", "explanation" => "capital"}]
      }

      assert {:ok, 0} = Flashcards.ingest_correction(:entry, 1, feedback)
      assert Flashcards.count_cards() == 0
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
  end

  describe "progress + completed_dates" do
    test "today_progress counts distinct cards reviewed today" do
      set_target(5)
      c1 = new_card()
      c2 = new_card()
      {:ok, _} = Flashcards.review(c1, :pass)
      {:ok, _} = Flashcards.review(c2, :fail)

      progress = Flashcards.today_progress()
      assert progress.done == 2
    end

    test "today counts as complete once the quota is met" do
      set_target(2)
      c1 = new_card()
      c2 = new_card()
      {:ok, _} = Flashcards.review(c1, :pass)
      {:ok, _} = Flashcards.review(c2, :pass)

      assert Flashcards.today_progress().complete?
      assert MapSet.member?(Flashcards.completed_dates(), Clock.today())
    end

    test "an under-target day is not complete while cards remain" do
      set_target(5)
      for _ <- 1..5, do: new_card()
      [card | _] = Flashcards.due_today(5)
      {:ok, _} = Flashcards.review(card, :pass)

      refute Flashcards.today_progress().complete?
      refute MapSet.member?(Flashcards.completed_dates(), Clock.today())
    end
  end
end
