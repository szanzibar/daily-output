defmodule DailyOutputWeb.JournalLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock, Repo}
  alias DailyOutput.Activities.Activity

  @focus %{"category" => "verb", "title" => "Perfekt mit sein", "body" => "Bewegung: sein."}

  defp journal(minutes_ago, body \\ nil) do
    Repo.insert!(%Activity{
      kind: "journal",
      date: Clock.today(),
      prompt: "Erzähl von deinem Wochenende.",
      focus: @focus,
      body: body,
      inserted_at:
        DateTime.utc_now() |> DateTime.add(-minutes_ago, :minute) |> DateTime.truncate(:second)
    })
  end

  test "Finish stays hidden until 5:00 after the start", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/journal/#{journal(1).id}")
    assert has_element?(view, "#focus-banner")
    assert has_element?(view, "#prompt")
    assert has_element?(view, "#finish-countdown")
    refute has_element?(view, "#finish")

    {:ok, view, _html} = live(conn, ~p"/journal/#{journal(6, "Hallo").id}")
    assert has_element?(view, "#finish")
    refute has_element?(view, "#finish-countdown")
  end

  test "the draft autosaves and keeps a local copy", %{conn: conn} do
    activity = journal(1)
    {:ok, view, _html} = live(conn, ~p"/journal/#{activity.id}")

    assert has_element?(view, "#journal-editor[data-persist-key='journal-#{activity.id}']")
    view |> form("#journal-form", body: "Am Samstag bin ich gewandert.") |> render_change()

    assert Activities.get!(activity.id).body == "Am Samstag bin ich gewandert."
  end

  test "Finish reviews the text, then shows the results", %{conn: conn} do
    activity = journal(6)

    expect_ai(%{
      "corrected" => "Am Samstag bin ich gewandert.",
      "corrections" => [],
      "summary" => "You went hiking.",
      "focus_result" => %{"used" => true, "correct" => true, "comment" => "Richtig!"}
    })

    {:ok, view, _html} = live(conn, ~p"/journal/#{activity.id}")
    view |> form("#journal-form", body: "Am Samstag bin ich gewandert.") |> render_submit()
    assert has_element?(view, "#finish-loading")

    render_async(view)

    assert has_element?(view, "#results #journal-corrections")
    assert has_element?(view, "#results #focus-result")
    assert has_element?(view, "#continue[href='/']")
    assert Activities.get!(activity.id).completed_at
  end

  test "a failed review keeps the text and offers a retry", %{conn: conn} do
    activity = journal(6)

    Req.Test.expect(DailyOutput.AI, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{"message" => "Invalid request.", "type" => "invalid_request_error"}
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/journal/#{activity.id}")
    view |> form("#journal-form", body: "Am Samstag bin ich gewandert.") |> render_submit()
    render_async(view)

    assert has_element?(view, "#finish-error")
    assert has_element?(view, "#journal-editor", "Am Samstag bin ich gewandert.")
  end
end
