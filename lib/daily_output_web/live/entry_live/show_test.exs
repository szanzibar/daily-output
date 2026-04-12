defmodule DailyOutputWeb.EntryLive.ShowTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{FocusTopics, Journal}

  test "override focus result marks entry as used and complete", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use also as conjunction",
        source_text: "focus-source-#{unique}",
        source_type: "entry",
        source_id: unique
      })

    {:ok, entry} =
      Journal.create_entry(%{
        body: "Heute war ein ruhiger Tag, also bleibe ich zu Hause.",
        language: "de",
        focus_topic_id: topic.id
      })

    {:ok, entry} =
      Journal.save_feedback(entry, %{
        "annotated_text" => "Heute war ein ruhiger Tag, also bleibe ich zu Hause.",
        "annotations" => [],
        "commentary" => [],
        "encouragement" => "Gut!",
        "focus_result" => %{
          "used" => false,
          "correct" => false,
          "comment" => "Nicht verwendet."
        }
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, ~s(button[phx-click="override_focus_result"]))

    render_click(view, "override_focus_result")

    reloaded = Journal.get_entry!(entry.id)
    assert reloaded.feedback["focus_result"]["used"] == true
    refute is_nil(reloaded.completed_at)

    refute has_element?(view, ~s(button[phx-click="override_focus_result"]))
  end
end
