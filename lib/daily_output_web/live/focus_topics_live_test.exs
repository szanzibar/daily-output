defmodule DailyOutputWeb.FocusTopicsLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.FocusTopics

  test "renders focus topic markdown as styled html, not raw characters", %{conn: conn} do
    {:ok, _topic} =
      FocusTopics.create_topic(%{
        text: "The **desto** rule: *je ... desto*",
        source_text: "src",
        source_type: "entry",
        source_id: 1
      })

    {:ok, _view, html} = live(conn, ~p"/focus")

    assert html =~ "<strong>desto</strong>"
    assert html =~ "<em>je ... desto</em>"
    refute html =~ "**desto**"
  end
end
