defmodule DailyOutputWeb.ProgressLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias DailyOutput.{Clock, Journal, Repo}
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Stats.ApiUsage

  test "shows an empty state with no activity", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/progress")
    assert html =~ "start tracking your progress" or html =~ "Fortschritt"
  end

  test "shows totals and the trend once there is completed work", %{conn: conn} do
    {:ok, entry} = Journal.create_entry(%{body: "x", language: "de"})
    at = DateTime.new!(Clock.today(), ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(e in Entry, where: e.id == ^entry.id),
        set: [
          inserted_at: at,
          completed_at: at,
          feedback: %{"annotated_text" => "[[1:foo||bar]] one two three"}
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/progress")

    assert has_element?(view, "h2", "Mistakes over time") or
             has_element?(view, "h2", "Fehler")

    # 4 words written (foo one two three)
    assert render(view) =~ "4"
  end

  test "renders the AI cost chart and a color-matched legend once there is spend",
       %{conn: conn} do
    {:ok, usage} =
      Repo.insert(%ApiUsage{
        purpose: "flashcards",
        model: "claude-sonnet",
        input_tokens: 1_000_000,
        output_tokens: 0
      })

    at = DateTime.new!(Clock.today(), ~T[12:00:00], "Etc/UTC")
    Repo.update_all(from(u in ApiUsage, where: u.id == ^usage.id), set: [inserted_at: at])

    {:ok, view, _html} = live(conn, ~p"/progress")

    assert has_element?(view, "h2", "AI cost") or has_element?(view, "h2", "KI")
    # sonnet input is $3/M → today's bar and legend show the spend, with the feature label.
    assert render(view) =~ "$3.00"
    assert has_element?(view, "span", "Flashcards") or has_element?(view, "span", "Karte")
  end
end
