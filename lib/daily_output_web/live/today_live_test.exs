defmodule DailyOutputWeb.TodayLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Today}

  test "shows today's step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#today-activity")

    {:activity, activity} = Today.next_step()
    Activities.complete(activity, %{}, nil)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#today-done")
  end
end
