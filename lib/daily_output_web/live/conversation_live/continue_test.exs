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

    feedback = %{
      "annotated_text" => "Heute war ein guter Tag.",
      "annotations" => [],
      "commentary" => [],
      "encouragement" => "Stark!"
    }

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
      "annotated_text" => "Heute war ein ruhiger Tag.",
      "annotations" => [],
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
      "annotated_text" => "Ich besuche heute meine Freundin.",
      "annotations" => [],
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
end
