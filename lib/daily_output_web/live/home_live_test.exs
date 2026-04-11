defmodule DailyOutputWeb.HomeLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Conversations, FocusTopics, Journal}

  test "routes draft items to edit and continue pages", %{conn: conn} do
    entry_focus = create_focus_topic!(%{text: "Entry focus", source_type: "entry"})

    {:ok, entry} =
      Journal.create_entry(%{
        body: "Draft entry body",
        language: "de",
        focus_topic_id: entry_focus.id
      })

    conversation_focus =
      create_focus_topic!(%{text: "Conversation focus", source_type: "conversation"})

    {:ok, conversation} =
      Conversations.create_conversation(%{
        topic: "Draft conversation topic",
        language: "de",
        focus_topic_id: conversation_focus.id
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(a[href="/entries/#{entry.id}/edit"]))
    assert has_element?(view, ~s(a[href="/conversations/#{conversation.id}/continue"]))

    refute has_element?(view, ~s(a[href="/entries/#{entry.id}"]))
    refute has_element?(view, ~s(a[href="/conversations/#{conversation.id}"]))
  end

  test "routes feedback-without-completion items to show pages for review", %{conn: conn} do
    entry_focus = create_focus_topic!(%{text: "Entry focus", source_type: "entry"})

    {:ok, entry} =
      Journal.create_entry(%{
        body: "Draft entry body",
        language: "de",
        focus_topic_id: entry_focus.id
      })

    {:ok, _entry} =
      Journal.save_feedback(entry, %{
        "annotated_text" => "Draft entry body",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Weiter so",
        "focus_result" => %{"used" => false, "correct" => false, "comment" => "Noch nicht."}
      })

    conversation_focus =
      create_focus_topic!(%{text: "Conversation focus", source_type: "conversation"})

    {:ok, conversation} =
      Conversations.create_conversation(%{
        topic: "Draft conversation topic",
        language: "de",
        focus_topic_id: conversation_focus.id
      })

    {:ok, _conversation} =
      Conversations.save_feedback(conversation, %{
        "annotated_text" => "Draft conversation topic",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Weiter so",
        "focus_result" => %{"used" => false, "correct" => false, "comment" => "Noch nicht."}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(a[href="/entries/#{entry.id}"]))
    assert has_element?(view, ~s(a[href="/conversations/#{conversation.id}"]))

    refute has_element?(view, ~s(a[href="/entries/#{entry.id}/edit"]))
    refute has_element?(view, ~s(a[href="/conversations/#{conversation.id}/continue"]))
  end

  defp create_focus_topic!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      text: "Focus #{unique}",
      source_text: "source-#{unique}",
      source_type: "entry",
      source_id: unique
    }

    {:ok, topic} = FocusTopics.create_topic(Map.merge(defaults, attrs))
    topic
  end
end
