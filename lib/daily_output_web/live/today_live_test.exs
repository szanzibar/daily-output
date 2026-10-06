defmodule DailyOutputWeb.TodayLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock, Repo, Today}
  alias DailyOutput.Flashcards.{Card, CompletedDay}

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
    assert has_element?(view, "#offers #bonus")
    refute has_element?(view, "#practice-more")

    view |> element("#bonus") |> render_click()
    assert_redirect(view, ~p"/")

    # Back through `/`, as a connected mount like the browser's live navigation.
    assert [_main, bonus] = Activities.today()
    {:ok, history, _html} = live(conn, ~p"/history")
    assert {:error, {:live_redirect, %{to: path}}} = live_redirect(history, to: ~p"/")
    assert path == "/#{bonus.kind}/#{bonus.id}"
  end

  test "cards still due after the day link to extra practice, which leaves the streak alone",
       %{conn: conn} do
    {:activity, main} = Today.next_step()
    Activities.complete(main, %{}, nil)
    assert Today.next_step() == :done
    streak = Today.streak()

    cards =
      for target <- ["Ich ging.", "Ich lief."],
          do: Repo.insert!(%Card{target_text: target, native_text: "I went.", language: "de"})

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#offers #bonus")
    assert has_element?(view, "#offers #practice-more", "2")

    {:ok, practice, _html} =
      view
      |> element("#practice-more")
      |> render_click()
      |> follow_redirect(conn, ~p"/flashcards/more")

    assert has_element?(practice, "#card-count", "2")
    card = Enum.find(cards, &has_element?(practice, "#answer-#{&1.id}"))
    practice |> form("form", %{answer: card.target_text}) |> render_submit()
    assert has_element?(practice, "#card-count", "1")

    {:ok, refreshed, _html} = live(conn, ~p"/flashcards/more")
    assert has_element?(refreshed, "#card-count", "1")
    [last] = cards -- [card]
    refreshed |> form("form", %{answer: last.target_text}) |> render_submit()
    send(refreshed.pid, :advance)
    assert_redirect(refreshed, ~p"/")

    assert Today.streak() == streak
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#practice-more")
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
    refute has_element?(view, "#practice-more")
  end

  test "after the bonus, cards still due are the only offer", %{conn: conn} do
    {:activity, main} = Today.next_step()
    Activities.complete(main, %{}, nil)
    Today.next_step()
    Activities.complete(Today.start_bonus(), %{}, nil)
    Repo.insert!(%Card{target_text: "Ich ging.", native_text: "I went.", language: "de"})

    {:ok, view, _html} = live(conn, ~p"/")
    # Same row as the card offer, so they sit side by side.
    assert has_element?(view, "#offers #bonus-done")
    assert has_element?(view, "#offers #practice-more", "1")
    refute has_element?(view, "#bonus")
  end

  test "with freezes at the cap, the bonus says they're full instead of +1", %{conn: conn} do
    for days_ago <- 1..3 do
      date = Date.add(Clock.today(), -days_ago)

      for kind <- ~w(conversation journal),
          do: Activities.create(%{kind: kind, date: date, completed_at: DateTime.utc_now()})

      Repo.insert!(%CompletedDay{day: date})
    end

    {:activity, main} = Today.next_step()
    Activities.complete(main, %{}, nil)
    Today.next_step()
    Activities.complete(Today.start_bonus(), %{}, nil)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#bonus-done #freezes-full")
  end
end
