defmodule DailyOutputWeb.ConversationLive.ContinueTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Conversations, FocusTopics}

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
