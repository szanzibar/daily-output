defmodule DailyOutputWeb.ConversationLive.ContinueTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Clock, Conversations, FocusTopics}

  # Seed alternating messages ending on the partner, so mounting Continue doesn't kick
  # off a real AI request (which the auto-reply path would do for a trailing user turn).
  defp seed_exchanges(conversation, user_turns) do
    for i <- 1..user_turns do
      {:ok, _} = Conversations.add_message(conversation, %{role: "user", body: "Nachricht #{i}"})

      {:ok, _} =
        Conversations.add_message(conversation, %{role: "assistant", body: "Antwort #{i}"})
    end
  end

  test "done is hidden below the warm-up floor", %{conn: conn} do
    {:ok, conversation} =
      Conversations.create_conversation(%{topic: "Wie war dein Tag?", language: "de"})

    seed_exchanges(conversation, 1)

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

    refute has_element?(view, ~s(button[phx-click="complete"]))
  end

  test "a warm-up conversation at the floor can finish and marks the day partial", %{conn: conn} do
    {:ok, conversation} =
      Conversations.create_conversation(%{topic: "Wie war dein Tag?", language: "de"})

    seed_exchanges(conversation, Conversations.warmup_exchanges())

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

    # Done unlocks at the warm-up floor, well below the default min_exchanges target.
    assert has_element?(view, ~s(button[phx-click="complete"]))

    # Completion no longer re-corrects — it stores the end-of-conversation assessment.
    feedback = %{"commentary" => [], "encouragement" => "Stark!"}

    send(view.pid, {:feedback_loaded, {:ok, feedback}})

    assert_redirect(view, ~p"/conversations/#{conversation.id}")

    reloaded = Conversations.get_conversation!(conversation.id)
    refute is_nil(reloaded.completed_at)
    assert FocusTopics.day_status(Clock.today()) == :partial
  end

  test "focus topic not used keeps conversation open", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use besuchen + object",
        source_text: "focus-source-#{unique}",
        source_type: "conversation",
        source_id: unique
      })

    {:ok, conversation} =
      Conversations.create_conversation(%{
        topic: "Wie war dein Tag?",
        language: "de",
        focus_topic_id: topic.id
      })

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

    feedback = %{
      "commentary" => [],
      "encouragement" => "Gut!",
      "focus_result" => %{"used" => false, "correct" => false, "comment" => "Nicht benutzt."}
    }

    send(view.pid, {:feedback_loaded, {:ok, feedback}})

    assert_redirect(view, ~p"/conversations/#{conversation.id}")

    reloaded = Conversations.get_conversation!(conversation.id)
    assert is_nil(reloaded.completed_at)
    assert reloaded.feedback["focus_result"]["used"] == false
  end

  test "focus topic attempted marks conversation complete", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use besuchen + object",
        source_text: "focus-source-#{unique}",
        source_type: "conversation",
        source_id: unique
      })

    {:ok, conversation} =
      Conversations.create_conversation(%{
        topic: "Was hast du heute gemacht?",
        language: "de",
        focus_topic_id: topic.id
      })

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

    feedback = %{
      "commentary" => [],
      "encouragement" => "Super!",
      "focus_result" => %{"used" => true, "correct" => true, "comment" => "Treffer."}
    }

    send(view.pid, {:feedback_loaded, {:ok, feedback}})

    assert_redirect(view, ~p"/conversations/#{conversation.id}")

    reloaded = Conversations.get_conversation!(conversation.id)
    refute is_nil(reloaded.completed_at)
    assert reloaded.feedback["focus_result"]["used"] == true
  end

  # A conversation with one user message, ending on the partner so mounting Continue
  # doesn't kick off a real AI auto-reply.
  defp seed_correctable do
    {:ok, conversation} =
      Conversations.create_conversation(%{topic: "Wie war dein Tag?", language: "de"})

    {:ok, user_msg} =
      Conversations.add_message(conversation, %{role: "user", body: "Ich gehe heim"})

    {:ok, _partner} =
      Conversations.add_message(conversation, %{role: "assistant", body: "Schön!"})

    {conversation, user_msg}
  end

  @sample_correction %{
    "annotated_text" => "Ich [[1:gehe||ging]] heim",
    "annotations" => [%{"id" => 1, "explanation" => "Vergangenheit", "category" => "verb"}]
  }

  describe "per-message corrections" do
    test "a stored user-message correction renders inline on mount", %{conn: conn} do
      {conversation, user_msg} = seed_correctable()
      {:ok, _} = Conversations.save_message_feedback(user_msg, @sample_correction)

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

      assert has_element?(view, "#annotated-msg-#{user_msg.id}")
    end

    test "an incoming correction updates that bubble live and persists", %{conn: conn} do
      {conversation, user_msg} = seed_correctable()

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")
      refute has_element?(view, "#annotated-msg-#{user_msg.id}")

      send(view.pid, {:message_corrected, user_msg.id, {:ok, @sample_correction}})

      assert has_element?(view, "#annotated-msg-#{user_msg.id}")

      reloaded = Conversations.get_conversation!(conversation.id)
      corrected = Enum.find(reloaded.messages, &(&1.id == user_msg.id))
      assert [%{"category" => "verb"}] = corrected.feedback["annotations"]
    end

    test "a failed correction leaves the chat usable", %{conn: conn} do
      {conversation, user_msg} = seed_correctable()

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

      send(view.pid, {:message_corrected, user_msg.id, {:error, :api_key_not_set}})

      refute has_element?(view, "#annotated-msg-#{user_msg.id}")
      assert has_element?(view, "form[phx-submit=\"send\"]")
    end

    test "branching a completed conversation into a new version keeps prior corrections",
         %{conn: conn} do
      {conversation, user_msg} = seed_correctable()
      {:ok, _} = Conversations.save_message_feedback(user_msg, @sample_correction)

      # A completed-with-feedback conversation: opening /continue branches into a new version.
      {:ok, _} =
        Conversations.save_feedback(conversation, %{"commentary" => [], "encouragement" => "Gut!"})

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}/continue")

      # The copied user message carries its corrections over (rendered via AnnotatedText),
      # so the new version is not a blank slate.
      assert has_element?(view, ~s([id^="annotated-msg-"]))
    end
  end
end
