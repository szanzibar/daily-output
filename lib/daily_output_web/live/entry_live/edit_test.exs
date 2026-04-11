defmodule DailyOutputWeb.EntryLive.EditTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.Journal

  test "blocks done while draft timer is active", %{conn: conn} do
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

  test "word-based heuristic unlocks done after page load", %{conn: conn} do
    long_body =
      List.duplicate("Heute schreibe ich konzentriert ueber meinen Tag.", 120)
      |> Enum.join(" ")

    {:ok, entry} =
      Journal.create_entry(%{
        body: long_body,
        language: "de"
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    refute has_element?(view, ~s(button[phx-click="resubmit"][disabled]))
  end

  test "typing more words does not unlock done before reload", %{conn: conn} do
    {:ok, entry} =
      Journal.create_entry(%{
        body: "",
        language: "de"
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}/edit")

    assert has_element?(view, ~s(button[phx-click="resubmit"][disabled]))

    long_body =
      List.duplicate("Ich uebe bewusst mit vielen Woertern fuer den Timer.", 120)
      |> Enum.join(" ")

    render_hook(view, "update_body", %{"body" => long_body})

    assert has_element?(view, ~s(button[phx-click="resubmit"][disabled]))
  end
end
