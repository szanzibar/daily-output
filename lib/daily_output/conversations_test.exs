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

  describe "copy_message/2" do
    test "copies role, body, and per-message feedback into another conversation" do
      source_convo = create_conversation()
      {:ok, msg} = Conversations.add_message(source_convo, %{role: "user", body: "Ich gehe heim"})

      {:ok, _} =
        Conversations.save_message_feedback(msg, %{
          "annotated_text" => "Ich [[1:gehe||ging]] heim",
          "annotations" => [%{"id" => 1, "explanation" => "Vergangenheit", "category" => "verb"}]
        })

      msg = Conversations.get_conversation!(source_convo.id).messages |> hd()

      target_convo = create_conversation()
      {:ok, copy} = Conversations.copy_message(target_convo, msg)

      assert copy.conversation_id == target_convo.id
      assert copy.role == "user"
      assert copy.body == "Ich gehe heim"
      assert copy.feedback["annotated_text"] == "Ich [[1:gehe||ging]] heim"
      assert [%{"category" => "verb"}] = copy.feedback["annotations"]
    end

    test "copies a message that has no feedback" do
      source_convo = create_conversation()
      {:ok, msg} = Conversations.add_message(source_convo, %{role: "assistant", body: "Hallo!"})

      target_convo = create_conversation()
      {:ok, copy} = Conversations.copy_message(target_convo, msg)

      assert copy.body == "Hallo!"
      assert is_nil(copy.feedback)
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

  describe "save_message_feedback/2" do
    test "stores normalized per-message feedback on a message" do
      convo = create_conversation()
      {:ok, msg} = Conversations.add_message(convo, %{role: "user", body: "Ich gehe heim"})

      feedback = %{
        "annotated_text" => "Ich [[1:gehe||ging]] heim",
        "annotations" => [%{"id" => 1, "explanation" => "Vergangenheit", "category" => "verb"}]
      }

      {:ok, updated} = Conversations.save_message_feedback(msg, feedback)
      assert updated.feedback["annotated_text"] == "Ich [[1:gehe||ging]] heim"
      assert [%{"category" => "verb"}] = updated.feedback["annotations"]
    end

    test "accepts a message id and normalizes the category" do
      convo = create_conversation()
      {:ok, msg} = Conversations.add_message(convo, %{role: "user", body: "Test"})

      feedback = %{
        "annotated_text" => "Test",
        "annotations" => [%{"id" => 1, "explanation" => "fix", "category" => "spelling"}]
      }

      {:ok, updated} = Conversations.save_message_feedback(msg.id, feedback)
      assert [%{"id" => 1, "category" => "spelling"}] = updated.feedback["annotations"]
    end
  end

  describe "mistake_analysis/1" do
    # Build a user message with `categories` worth of corrections over `body`.
    defp user_msg(body, categories) do
      annotations =
        categories
        |> Enum.with_index(1)
        |> Enum.map(fn {cat, id} -> %{"id" => id, "explanation" => "x", "category" => cat} end)

      feedback =
        if categories == [],
          do: %{"annotated_text" => body, "annotations" => []},
          else: %{"annotated_text" => body, "annotations" => annotations}

      %{role: "user", body: body, feedback: feedback}
    end

    test "a category flagged once early, then never again, is resolved" do
      messages = [
        user_msg("eins zwei drei", ["gender"]),
        %{role: "assistant", body: "ok", feedback: nil},
        user_msg("vier funf sechs", []),
        user_msg("sieben acht neun", [])
      ]

      analysis = Conversations.mistake_analysis(messages)

      assert "gender" in analysis["resolved_categories"]
      assert analysis["repeated_categories"] == []
    end

    test "a category that recurs across messages is still repeating" do
      messages = [
        user_msg("eins zwei drei", ["case"]),
        user_msg("vier funf sechs", ["case"]),
        user_msg("sieben acht neun", [])
      ]

      analysis = Conversations.mistake_analysis(messages)

      assert "case" in analysis["repeated_categories"]
      refute "case" in analysis["resolved_categories"]
    end

    test "computes early vs late correction rate per 100 words" do
      # early half: 1 msg, 3 words, 1 correction → 33.3; late half: 1 msg, 3 words, 0 → 0.0
      messages = [
        user_msg("eins zwei drei", ["verb"]),
        user_msg("vier funf sechs", [])
      ]

      analysis = Conversations.mistake_analysis(messages)

      assert analysis["early_rate"] == 33.3
      assert analysis["late_rate"] == 0.0
      assert analysis["total_corrections"] == 1
      assert analysis["by_category"] == %{"verb" => 1}
    end

    test "a category only in the final message is neither resolved nor repeating" do
      messages = [
        user_msg("eins zwei drei", []),
        user_msg("vier funf sechs", ["spelling"])
      ]

      analysis = Conversations.mistake_analysis(messages)

      refute "spelling" in analysis["resolved_categories"]
      refute "spelling" in analysis["repeated_categories"]
    end

    test "empty / feedback-free conversation yields zeros and nil rates" do
      messages = [%{role: "user", body: "hallo welt", feedback: nil}]
      analysis = Conversations.mistake_analysis(messages)

      assert analysis["total_corrections"] == 0
      assert analysis["resolved_categories"] == []
      assert analysis["repeated_categories"] == []
      assert is_nil(analysis["early_rate"])
      assert analysis["late_rate"] == 0.0
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
