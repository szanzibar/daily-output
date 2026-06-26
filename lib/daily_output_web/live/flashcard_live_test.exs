defmodule DailyOutputWeb.FlashcardLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Flashcards, Repo}
  alias DailyOutput.Flashcards.Card

  defp new_card(target, native) do
    {:ok, card} =
      %Card{}
      |> Card.changeset(%{target_text: target, native_text: native, language: "de", state: "new"})
      |> Repo.insert()

    card
  end

  describe "study page" do
    test "shows the empty state when nothing is due", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/flashcards")
      # No card to study: no input, and the done screen links home.
      refute has_element?(view, "textarea[name=answer]")
      assert has_element?(view, ~s(a[href="/"]))
    end

    test "shows the native prompt and an auto-focused input", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      assert has_element?(view, "textarea[name=answer]")
      assert render(view) =~ "I went home."
    end

    test "a correct answer celebrates with confetti, records a review, then advances",
         %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      html =
        view
        |> form("form", %{answer: "Ich ging nach Hause."})
        |> render_submit()

      # Brief green celebration showing the answer, with a confetti pop.
      assert html =~ "Ich ging nach Hause."
      assert_push_event(view, "confetti", %{})
      assert Flashcards.today_progress().done == 1

      # The scheduled tick auto-advances (only one card → done, no input).
      send(view.pid, :advance_after_correct)
      refute has_element?(view, "textarea[name=answer]")
    end

    test "a wrong answer reveals the word-level diff", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      html =
        view
        |> form("form", %{answer: "Ich gehe nach Hause."})
        |> render_submit()

      # Unified word-level diff: wrong word struck out, correct word in green.
      assert html =~ "correction-deleted"
      assert html =~ "correction-added"
      assert has_element?(view, "button[phx-click=continue]")
    end

    test "the reveal keeps the english visible and lets you fix the card inline", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      html = view |> form("form", %{answer: "falsch"}) |> render_submit()

      # English prompt stays visible on the reveal, with an edit affordance.
      assert html =~ "I went home."
      assert has_element?(view, "button[phx-click=edit]")

      # Open the inline editor, fix the translation, and save.
      view |> element("button[phx-click=edit]") |> render_click()

      view
      |> form("#flashcard-edit-form", %{
        card: %{native_text: "I returned home.", target_text: "Ich ging nach Hause."}
      })
      |> render_submit()

      assert Repo.get(Card, card.id).native_text == "I returned home."
    end
  end

  describe "manage page" do
    test "lists, edits, and deletes cards", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, html} = live(conn, ~p"/flashcards/manage")
      assert html =~ "Ich ging nach Hause."

      view |> element("button[phx-click=edit][phx-value-id='#{card.id}']") |> render_click()

      view
      |> form("form", %{
        card: %{target_text: "Ich fuhr nach Hause.", native_text: "I drove home."}
      })
      |> render_submit()

      assert Repo.get(Card, card.id).target_text == "Ich fuhr nach Hause."

      view
      |> element("button[phx-click=delete][phx-value-id='#{card.id}']")
      |> render_click()

      assert Flashcards.list_cards() == []
    end
  end
end
