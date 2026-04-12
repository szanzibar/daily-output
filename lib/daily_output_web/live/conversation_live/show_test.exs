defmodule DailyOutputWeb.ConversationLive.ShowTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Conversations, FocusTopics}

  test "override focus result marks conversation as used and complete", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use also as conjunction",
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

    {:ok, conversation} =
      Conversations.save_feedback(conversation, %{
        "annotated_text" => "Ich bleibe heute zu Hause, also kann ich lernen.",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Gut!",
        "focus_result" => %{
          "used" => false,
          "correct" => false,
          "comment" => "Nicht verwendet."
        }
      })

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

    assert has_element?(view, ~s(button[phx-click="override_focus_result"]))

    render_click(view, "override_focus_result")

    reloaded = Conversations.get_conversation!(conversation.id)
    assert reloaded.feedback["focus_result"]["used"] == true
    refute is_nil(reloaded.completed_at)

    refute has_element?(view, ~s(button[phx-click="override_focus_result"]))
  end
end
