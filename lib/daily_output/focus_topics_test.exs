defmodule DailyOutput.FocusTopicsTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Clock, Conversations, FocusTopics, Journal, Repo, Settings}
  alias DailyOutput.Conversations.Conversation
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Flashcards.{Card, Review}

  defp create_topic(attrs \\ %{}) do
    {:ok, topic} =
      FocusTopics.create_topic(
        Map.merge(
          %{
            text: "Test topic",
            source_text: "Original tip text",
            source_type: "entry",
            source_id: 1
          },
          attrs
        )
      )

    topic
  end

  describe "create_topic/1" do
    test "creates with valid attrs" do
      assert {:ok, topic} =
               FocusTopics.create_topic(%{
                 text: "Use Dativ after 'mit'",
                 source_type: "entry",
                 source_id: 1
               })

      assert topic.text == "Use Dativ after 'mit'"
      assert is_nil(topic.mastered_at)
    end

    test "requires text" do
      assert {:error, changeset} =
               FocusTopics.create_topic(%{source_type: "entry", source_id: 1})

      assert %{text: _} = errors_on(changeset)
    end

    test "validates source_type" do
      assert {:error, changeset} =
               FocusTopics.create_topic(%{text: "test", source_type: "invalid", source_id: 1})

      assert %{source_type: _} = errors_on(changeset)
    end
  end

  describe "list_active_topics/0" do
    test "returns non-mastered topics" do
      t1 = create_topic(%{text: "active", source_text: "source1"})
      t2 = create_topic(%{text: "mastered", source_text: "source2"})
      {:ok, _} = FocusTopics.master_topic(t2)

      active = FocusTopics.list_active_topics()
      assert length(active) == 1
      assert hd(active).id == t1.id
    end
  end

  describe "has_active_topics?/0" do
    test "returns false when empty" do
      refute FocusTopics.has_active_topics?()
    end

    test "returns true with active topics" do
      create_topic()
      assert FocusTopics.has_active_topics?()
    end

    test "returns false when all mastered" do
      topic = create_topic()
      {:ok, _} = FocusTopics.master_topic(topic)
      refute FocusTopics.has_active_topics?()
    end
  end

  describe "master_topic/1" do
    test "sets mastered_at" do
      topic = create_topic()
      assert is_nil(topic.mastered_at)
      {:ok, mastered} = FocusTopics.master_topic(topic)
      refute is_nil(mastered.mastered_at)
    end
  end

  describe "delete_topic/1" do
    test "removes the topic" do
      topic = create_topic()
      {:ok, _} = FocusTopics.delete_topic(topic)
      assert FocusTopics.list_all_topics() == []
    end
  end

  describe "daily_challenge_status/0" do
    test "returns :none for both with no activity" do
      status = FocusTopics.daily_challenge_status()
      assert status.entry == :none
      assert status.conversation == :none
      assert status.all_done == false
    end

    test "entry with feedback and completed_at is complete" do
      {:ok, entry} = DailyOutput.Journal.create_entry(%{body: "test", language: "de"})
      {:ok, entry} = DailyOutput.Journal.save_feedback(entry, %{"annotated_text" => "test"})
      DailyOutput.Journal.complete_entry(entry)
      status = FocusTopics.daily_challenge_status()
      assert status.entry == :complete
    end

    test "entry with feedback but without completed_at is not complete" do
      {:ok, entry} = DailyOutput.Journal.create_entry(%{body: "test", language: "de"})
      DailyOutput.Journal.save_feedback(entry, %{"annotated_text" => "test"})

      status = FocusTopics.daily_challenge_status()
      assert status.entry == :none
    end

    test "conversation with feedback but without completed_at is not complete" do
      {:ok, conversation} =
        DailyOutput.Conversations.create_conversation(%{topic: "test", language: "de"})

      DailyOutput.Conversations.save_feedback(conversation, %{"annotated_text" => "test"})

      status = FocusTopics.daily_challenge_status()
      assert status.conversation == :none
    end

    test "conversation with feedback and completed_at is complete" do
      {:ok, conversation} =
        DailyOutput.Conversations.create_conversation(%{topic: "test", language: "de"})

      {:ok, conversation} =
        DailyOutput.Conversations.save_feedback(conversation, %{"annotated_text" => "test"})

      DailyOutput.Conversations.complete_conversation(conversation)

      status = FocusTopics.daily_challenge_status()
      assert status.conversation == :complete
    end
  end

  describe "current_streak/0" do
    test "returns 0 with no activity" do
      assert FocusTopics.current_streak() == 0
    end
  end

  describe "streak_milestone?/1" do
    test "true on the named milestones and every further century" do
      for n <- [3, 7, 14, 30, 50, 100, 200, 300] do
        assert FocusTopics.streak_milestone?(n), "expected #{n} to be a milestone"
      end
    end

    test "false for ordinary counts and non-integers" do
      for n <- [0, 1, 2, 5, 13, 99, 101, 150] do
        refute FocusTopics.streak_milestone?(n), "expected #{n} not to be a milestone"
      end

      refute FocusTopics.streak_milestone?(nil)
    end
  end

  describe "day_status/1 (tiered days)" do
    test "full when both tasks are done" do
      today = Clock.today()
      full_day_on(today)
      assert FocusTopics.day_status(today) == :full
    end

    test "partial with one task done" do
      today = Clock.today()
      complete_entry_on(today)
      assert FocusTopics.day_status(today) == :partial
    end

    test "none with no activity" do
      assert FocusTopics.day_status(Clock.today()) == :none
    end
  end

  describe "streak_info/0 (tiers + freezes)" do
    test "an unfinished today doesn't zero a streak ending yesterday" do
      today = Clock.today()
      complete_entry_on(Date.add(today, -1))

      info = FocusTopics.streak_info()
      assert info.count == 1
      assert info.today_status == :none
    end

    test "partial days keep the streak alive" do
      today = Clock.today()
      complete_entry_on(today)
      complete_conversation_on(Date.add(today, -1))

      assert FocusTopics.current_streak() == 2
    end

    test "a gap with no earned freeze ends the streak" do
      today = Clock.today()
      full_day_on(Date.add(today, -1))
      full_day_on(Date.add(today, -2))
      # offset 3 missing, only 2 full days earned → no freeze to bridge it

      assert FocusTopics.current_streak() == 2
      assert FocusTopics.streak_info().freezes_available == 0
    end

    test "an earned freeze bridges a one-day gap" do
      today = Clock.today()
      # 6 full days earns one freeze; offset 3 is intentionally missing
      for offset <- [1, 2, 4, 5, 6, 7], do: full_day_on(Date.add(today, -offset))

      info = FocusTopics.streak_info()
      assert info.count == 6
      assert info.freezes_available == 0
    end

    test "freezes stay available (unspent) on a clean streak" do
      today = Clock.today()
      for offset <- 1..5, do: full_day_on(Date.add(today, -offset))

      info = FocusTopics.streak_info()
      assert info.count == 5
      assert info.freezes_available == 1
    end
  end

  defp complete_entry_on(date) do
    backdate(Journal.create_entry(%{body: "x", language: "de"}), Entry, date)
  end

  defp complete_conversation_on(date) do
    backdate(Conversations.create_conversation(%{topic: "x", language: "de"}), Conversation, date)
  end

  defp full_day_on(date) do
    complete_entry_on(date)
    complete_conversation_on(date)
    complete_flashcards_on(date)
  end

  # A full flashcard day = the day's quota (set to 1 here) of distinct cards reviewed.
  defp complete_flashcards_on(date) do
    ensure_flashcard_target(1)

    {:ok, card} =
      %Card{}
      |> Card.changeset(%{
        target_text: "Satz #{System.unique_integer([:positive])}",
        native_text: "Sentence",
        language: "de",
        state: "review",
        due_at: DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, review} =
      %Review{} |> Review.changeset(%{card_id: card.id, result: true}) |> Repo.insert()

    at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC") |> DateTime.truncate(:second)
    {1, _} = Repo.update_all(from(r in Review, where: r.id == ^review.id), set: [inserted_at: at])
    :ok
  end

  defp ensure_flashcard_target(n) do
    {:ok, config} = Settings.ensure_config()
    {:ok, _} = Settings.update_config(config, %{flashcards_per_day: n})
  end

  defp backdate({:ok, record}, schema, date) do
    at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(r in schema, where: r.id == ^record.id),
        set: [inserted_at: at, completed_at: at, feedback: %{"annotated_text" => "x"}]
      )

    record
  end
end
