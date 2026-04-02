defmodule DailyOutput.ConversationsTest do
  use DailyOutput.DataCase

  alias DailyOutput.Conversations
  alias DailyOutput.Conversations.{Conversation, Message}

  defp create_conversation(attrs \\ %{}) do
    {:ok, convo} =
      Conversations.create_conversation(Map.merge(%{topic: "Test thema", language: "de"}, attrs))

    convo
  end

  describe "create_conversation/1" do
    test "creates with valid attrs" do
      assert {:ok, %Conversation{topic: "Wetter", language: "de"}} =
               Conversations.create_conversation(%{topic: "Wetter", language: "de"})
    end
  end

  describe "get_conversation!/1" do
    test "returns conversation with preloaded messages" do
      convo = create_conversation()
      Conversations.add_message(convo, %{role: "user", body: "Hallo"})
      loaded = Conversations.get_conversation!(convo.id)
      assert length(loaded.messages) == 1
    end

    test "excludes soft-deleted" do
      convo = create_conversation()
      {:ok, _} = Conversations.soft_delete_conversation(convo)
      assert_raise Ecto.NoResultsError, fn -> Conversations.get_conversation!(convo.id) end
    end
  end

  describe "add_message/2" do
    test "adds user message" do
      convo = create_conversation()

      assert {:ok, %Message{role: "user", body: "Hallo"}} =
               Conversations.add_message(convo, %{role: "user", body: "Hallo"})
    end

    test "adds assistant message" do
      convo = create_conversation()

      assert {:ok, %Message{role: "assistant"}} =
               Conversations.add_message(convo, %{role: "assistant", body: "Grüß dich!"})
    end

    test "rejects invalid role" do
      convo = create_conversation()

      assert {:error, changeset} =
               Conversations.add_message(convo, %{role: "system", body: "nope"})

      assert %{role: _} = errors_on(changeset)
    end
  end

  describe "list_messages/1" do
    test "returns messages in chronological order" do
      convo = create_conversation()
      {:ok, _} = Conversations.add_message(convo, %{role: "user", body: "first"})
      {:ok, _} = Conversations.add_message(convo, %{role: "assistant", body: "second"})
      msgs = Conversations.list_messages(convo)
      assert [%{body: "first"}, %{body: "second"}] = msgs
    end
  end

  describe "user_message_count/1" do
    test "counts only user messages" do
      convo = create_conversation()
      {:ok, _} = Conversations.add_message(convo, %{role: "user", body: "a"})
      {:ok, _} = Conversations.add_message(convo, %{role: "assistant", body: "b"})
      {:ok, _} = Conversations.add_message(convo, %{role: "user", body: "c"})
      assert Conversations.user_message_count(convo) == 2
    end
  end

  describe "complete_conversation/1" do
    test "sets completed_at" do
      convo = create_conversation()
      {:ok, completed} = Conversations.complete_conversation(convo)
      refute is_nil(completed.completed_at)
    end
  end

  describe "save_feedback/2" do
    test "stores feedback" do
      convo = create_conversation()
      feedback = %{"annotated_text" => "test", "annotations" => []}
      {:ok, updated} = Conversations.save_feedback(convo, feedback)
      assert updated.feedback["annotated_text"] == "test"
    end
  end

  describe "soft_delete_conversation/1" do
    test "sets deleted_at" do
      convo = create_conversation()
      {:ok, deleted} = Conversations.soft_delete_conversation(convo)
      refute is_nil(deleted.deleted_at)
    end
  end

  describe "versioning" do
    test "get_versions returns all conversations for the same day" do
      c1 = create_conversation(%{topic: "v1"})
      _c2 = create_conversation(%{topic: "v2"})
      versions = Conversations.get_versions(c1)
      assert length(versions) == 2
    end

    test "version_info returns total count" do
      _c1 = create_conversation(%{topic: "v1"})
      c2 = create_conversation(%{topic: "v2"})
      {_version, total} = Conversations.version_info(c2)
      assert total == 2
    end
  end
end
