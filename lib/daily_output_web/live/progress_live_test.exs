defmodule DailyOutputWeb.ProgressLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias DailyOutput.{Clock, Journal, Repo}
  alias DailyOutput.Journal.Entry

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
end
