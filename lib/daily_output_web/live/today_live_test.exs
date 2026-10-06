defmodule DailyOutputWeb.TodayLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock, Repo, Today}
  alias DailyOutput.Flashcards.Card

  test "a fresh day redirects to today's activity", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/")

    [activity] = Activities.today()
    assert path == "/#{activity.kind}/#{activity.id}"
  end

  test "a journal day redirects to the journal page", %{conn: conn} do
    activity = Activities.create(%{kind: "journal", focus: %{"category" => nil}})

    assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/")
    assert path == ~p"/journal/#{activity.id}"
  end

  test "a finished activity with cards due redirects to the cards", %{conn: conn} do
    Repo.insert!(%Card{target_text: "Ich ging.", native_text: "I went.", language: "de"})
    {:activity, activity} = Today.next_step()
    Activities.complete(activity, %{}, nil)

    assert {:error, {:live_redirect, %{to: "/flashcards"}}} = live(conn, ~p"/")
  end

  test "the done screen offers one bonus, which goes back through /", %{conn: conn} do
    {:activity, main} = Today.next_step()
    Activities.complete(main, %{}, nil)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#streak")
    assert has_element?(view, "#celebrate[data-key='#{Clock.today()}-passed']")
    refute has_element?(view, "#bonus-done")

    view |> element("#bonus") |> render_click()
    assert_redirect(view, ~p"/")

    # Back through `/`, as a connected mount like the browser's live navigation.
    assert [_main, bonus] = Activities.today()
    {:ok, history, _html} = live(conn, ~p"/history")
    assert {:error, {:live_redirect, %{to: path}}} = live_redirect(history, to: ~p"/")
    assert path == "/#{bonus.kind}/#{bonus.id}"
  end

  test "after the bonus, the done screen shows the freeze instead", %{conn: conn} do
    {:activity, main} = Today.next_step()
    Activities.complete(main, %{}, nil)
    Today.next_step()
    Activities.complete(Today.start_bonus(), %{}, nil)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#bonus-done")
    assert has_element?(view, "#celebrate[data-key='#{Clock.today()}-bonus']")
    refute has_element?(view, "#bonus")
  end
end
