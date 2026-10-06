defmodule DailyOutputWeb.HistoryLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock}

  test "lists finished activities newest first, each linking to its results", %{conn: conn} do
    journal =
      Activities.create(%{
        kind: "journal",
        date: Date.add(Clock.today(), -2),
        focus: %{"title" => "Perfekt mit sein"},
        summary: "You went hiking.",
        body: "Ich bin gewandert.",
        feedback: %{"annotated_text" => "Ich bin gewandert."},
        completed_at: DateTime.utc_now()
      })

    chat =
      Activities.create(%{
        kind: "conversation",
        date: Date.add(Clock.today(), -1),
        summary: "You talked about cooking.",
        completed_at: DateTime.utc_now()
      })

    unfinished = Activities.create(%{kind: "conversation"})

    {:ok, view, _html} = live(conn, ~p"/history")

    assert has_element?(
             view,
             "#history > #activity-#{chat.id}:first-child",
             "You talked about cooking."
           )

    assert has_element?(
             view,
             "#activity-#{journal.id}[href='/journal/#{journal.id}']",
             "Perfekt mit sein"
           )

    refute has_element?(view, "#activity-#{unfinished.id}")

    {:ok, page, _html} =
      view |> element("#activity-#{journal.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(page, "#results #journal-corrections")
    assert has_element?(page, "#back-to-history")
    refute has_element?(page, "#journal-form")
  end

  test "shows an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/history")
    assert has_element?(view, "#history-empty")
  end
end
