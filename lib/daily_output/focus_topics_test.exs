defmodule DailyOutput.FocusTopicsTest do
  use DailyOutput.DataCase

  alias DailyOutput.FocusTopics

  defp create_topic(attrs \\ %{}) do
    {:ok, topic} =
      FocusTopics.create_topic(
        Map.merge(
          %{text: "Test topic", source_text: "Original tip text", source_type: "entry", source_id: 1},
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

    test "entry with feedback is complete when no focus topics exist" do
      {:ok, entry} = DailyOutput.Journal.create_entry(%{body: "test", language: "de"})
      DailyOutput.Journal.save_feedback(entry, %{"annotated_text" => "test"})
      status = FocusTopics.daily_challenge_status()
      assert status.entry == :complete
    end
  end

  describe "current_streak/0" do
    test "returns 0 with no activity" do
      assert FocusTopics.current_streak() == 0
    end
  end
end
