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

  test "renders per-message corrections when messages carry feedback", %{conn: conn} do
    {:ok, conversation} =
      Conversations.create_conversation(%{topic: "Wie war dein Tag?", language: "de"})

    {:ok, user_msg} =
      Conversations.add_message(conversation, %{role: "user", body: "Ich gehe heim"})

    {:ok, _} =
      Conversations.save_message_feedback(user_msg, %{
        "annotated_text" => "Ich [[1:gehe||ging]] heim",
        "annotations" => [%{"id" => 1, "explanation" => "Vergangenheit", "category" => "verb"}]
      })

    # End-of-conversation assessment carries no corrections, just the wrap-up.
    {:ok, conversation} =
      Conversations.save_feedback(conversation, %{
        "commentary" => [],
        "encouragement" => "Weiter so!"
      })

    {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

    # The per-message correction renders inline; the legacy batch renderer is not used.
    assert has_element?(view, "#annotated-msg-#{user_msg.id}")
  end

  test "renders the within-conversation improvement panel when present", %{conn: conn} do
    {:ok, conversation} =
      Conversations.create_conversation(%{topic: "Wie war dein Tag?", language: "de"})

    {:ok, conversation} =
      Conversations.save_feedback(conversation, %{
        "commentary" => [],
        "encouragement" => "Gut!",
        "improvement_note" => "Du hast die Genus-Fehler nicht wiederholt!",
        "improvement" => %{
          "resolved_categories" => ["gender"],
          "repeated_categories" => ["case"],
          "early_rate" => 20.0,
          "late_rate" => 5.0
        }
      })

    {:ok, _view, html} = live(conn, ~p"/conversations/#{conversation.id}")

    # Assert on locale-independent data so the test holds regardless of UI language.
    assert html =~ "Du hast die Genus-Fehler nicht wiederholt!"
    assert html =~ "20.0"
    assert html =~ "5.0"
    # Resolved/repeating category labels (German in the default test locale).
    assert html =~ "Genus"
    assert html =~ "Kasus"
  end
end
