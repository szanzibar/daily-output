defmodule DailyOutputWeb.EntryLive.EditTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Journal, FocusTopics}

  test "blocks done until the writing floor is met", %{conn: conn} do
    {:ok, entry} =
      Journal.create_entry(%{
        body: "Kurzer Text",
        language: "de"
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    assert has_element?(view, ~s(button[phx-click="resubmit"][disabled]))

    render_click(view, "resubmit")

    reloaded = Journal.get_entry!(entry.id)
    assert is_nil(reloaded.completed_at)
    assert is_nil(reloaded.feedback)
  end

  test "a body above the floor unlocks done on load", %{conn: conn} do
    body = String.duplicate("wort ", Journal.floor_words())

    {:ok, entry} =
      Journal.create_entry(%{
        body: body,
        language: "de"
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    refute has_element?(view, ~s(button[phx-click="resubmit"][disabled]))
  end

  test "typing past the floor unlocks done live (soft timer, not a lock)", %{conn: conn} do
    {:ok, entry} =
      Journal.create_entry(%{
        body: "",
        language: "de"
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    assert has_element?(view, ~s(button[phx-click="resubmit"][disabled]))

    enough = String.duplicate("wort ", Journal.floor_words())
    render_hook(view, "update_body", %{"body" => enough})

    refute has_element?(view, ~s(button[phx-click="resubmit"][disabled]))
  end

  test "focus topic not used keeps entry as draft", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use besuchen + object",
        source_text: "focus-source-#{unique}",
        source_type: "entry",
        source_id: unique
      })

    {:ok, entry} =
      Journal.create_entry(%{
        body: "Heute war ein ruhiger Tag.",
        language: "de",
        focus_topic_id: topic.id
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    feedback = %{
      "annotated_text" => "Heute war ein ruhiger Tag.",
      "annotations" => [],
      "commentary" => [],
      "encouragement" => "Gut!",
      "focus_result" => %{"used" => false, "correct" => false, "comment" => "Nicht benutzt."}
    }

    send(view.pid, {:feedback_loaded, {:ok, feedback}, entry})

    assert_redirect(view, ~p"/entries/#{entry.id}")

    reloaded = Journal.get_entry!(entry.id)
    assert is_nil(reloaded.completed_at)
    assert reloaded.feedback["focus_result"]["used"] == false
  end

  test "focus topic attempted marks entry complete", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, topic} =
      FocusTopics.create_topic(%{
        text: "Use besuchen + object",
        source_text: "focus-source-#{unique}",
        source_type: "entry",
        source_id: unique
      })

    {:ok, entry} =
      Journal.create_entry(%{
        body: "Heute besuche ich meine Freundin.",
        language: "de",
        focus_topic_id: topic.id
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    feedback = %{
      "annotated_text" => "Heute besuche ich meine Freundin.",
      "annotations" => [],
      "commentary" => [],
      "encouragement" => "Super!",
      "focus_result" => %{"used" => true, "correct" => true, "comment" => "Treffer."}
    }

    send(view.pid, {:feedback_loaded, {:ok, feedback}, entry})

    assert_redirect(view, ~p"/entries/#{entry.id}")

    reloaded = Journal.get_entry!(entry.id)
    refute is_nil(reloaded.completed_at)
    assert reloaded.feedback["focus_result"]["used"] == true
  end
end
