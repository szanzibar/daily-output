defmodule DailyOutputWeb.JournalLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Stats}

  @focus %{"category" => "verb", "title" => "Perfekt mit sein", "body" => "Bewegung: sein."}

  defp journal(body \\ nil) do
    Activities.create(%{
      kind: "journal",
      prompt: "Erzähl von deinem Wochenende.",
      focus: @focus,
      body: body
    })
  end

  test "Finish shows up once 5:00 of writing time is logged", %{conn: conn} do
    Stats.track("journal", 299)
    {:ok, view, _html} = live(conn, ~p"/journal/#{journal("Hallo").id}")
    assert has_element?(view, "#focus-banner")
    assert has_element?(view, "#prompt #translate-prompt-button")
    assert has_element?(view, "#finish-countdown-time", "0:01")
    refute has_element?(view, "#finish")

    view
    |> element("#journal-time-tracker")
    |> render_hook("track_time", %{"section" => "journal", "seconds" => 1})

    assert has_element?(view, "#finish")
    refute has_element?(view, "#finish-countdown")
  end

  test "the draft autosaves and keeps a local copy", %{conn: conn} do
    activity = journal()
    {:ok, view, _html} = live(conn, ~p"/journal/#{activity.id}")

    assert has_element?(view, "#journal-editor[data-persist-key='journal-#{activity.id}']")
    view |> form("#journal-form", body: "Am Samstag bin ich gewandert.") |> render_change()

    assert Activities.get!(activity.id).body == "Am Samstag bin ich gewandert."
  end

  test "Finish reviews the text, then shows the results", %{conn: conn} do
    Stats.track("journal", 300)
    activity = journal()

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
    Stats.track("journal", 300)
    activity = journal()

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
