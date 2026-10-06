defmodule DailyOutputWeb.FlashcardLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Flashcards, Repo}
  alias DailyOutput.Flashcards.{Card, Review}

  defp new_card(target, native) do
    {:ok, card} =
      %Card{}
      |> Card.changeset(%{target_text: target, native_text: native, language: "de", state: "new"})
      |> Repo.insert()

    card
  end

  describe "card session" do
    test "with nothing due, the session goes back to /", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/flashcards")
    end

    test "a correct answer celebrates, records a review, and the last one ends the session",
         %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")
      assert has_element?(view, "#answer-#{card.id}[data-persist-key='answer-#{card.id}']")

      view |> form("form", %{answer: "Ich ging nach Hause."}) |> render_submit()

      assert_push_event(view, "confetti", %{})
      assert Repo.aggregate(Review, :count) == 1

      send(view.pid, :advance)
      assert_redirect(view, ~p"/")
    end

    test "a refresh keeps the counter and the order", %{conn: conn} do
      cards = for n <- ~w(eins zwei drei), do: new_card("Ich zähle #{n}.", "I count #{n}.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      first = Enum.find(cards, &has_element?(view, "#answer-#{&1.id}"))
      view |> form("form", %{answer: first.target_text}) |> render_submit()
      send(view.pid, :advance)
      second = Enum.find(cards, &has_element?(view, "#answer-#{&1.id}"))

      {:ok, refreshed, _html} = live(conn, ~p"/flashcards")
      assert has_element?(refreshed, "#card-count", "2 / 3")
      assert has_element?(refreshed, "#answer-#{second.id}")
    end

    test "a miss shows the fix, and a correct retype moves on without another review",
         %{conn: conn} do
      cards = [
        new_card("Ich ging nach Hause.", "I went home."),
        new_card("Ich ging zur Schule.", "I went to school.")
      ]

      {:ok, view, _html} = live(conn, ~p"/flashcards")
      assert has_element?(view, "#card-count", "1 / 2")

      card = Enum.find(cards, &has_element?(view, "#answer-#{&1.id}"))
      answer = String.replace(card.target_text, "ging", "gehe")
      view |> form("form", %{answer: answer}) |> render_submit()

      # Still card 1 while its fix shows.
      assert has_element?(view, "#card-count", "1 / 2")
      assert has_element?(view, "#card-fix-diff .correction-deleted", "gehe")
      assert has_element?(view, "#card-fix-diff .correction-added", "ging")
      # The miss narrows the card to a blank on the wrong word, for next time.
      assert Repo.get(Card, card.id).blank_indices == [1]

      # The retype asks the whole sentence again, and only a correct one moves on.
      assert has_element?(view, "#retype-#{card.id}")
      view |> form("form", %{answer: answer}) |> render_submit()
      assert has_element?(view, "#card-fix-diff .correction-deleted", "gehe")

      view |> form("form", %{answer: card.target_text}) |> render_submit()
      assert has_element?(view, "#card-correct")
      assert Repo.aggregate(Review, :count) == 1

      send(view.pid, :advance)
      assert has_element?(view, "#card-count", "2 / 2")
    end

    test "a cloze miss is retyped in the same blanks", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      card |> Ecto.Changeset.change(blank_indices: [1]) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("#cloze-#{card.id}", %{"blank" => %{"1" => "gehe"}}) |> render_submit()
      assert has_element?(view, "#retype-#{card.id} textarea.cloze-blank[name='blank[1]']")

      view |> form("#retype-#{card.id}", %{"blank" => %{"1" => "gehe"}}) |> render_submit()
      refute has_element?(view, "#card-correct")

      view |> form("#retype-#{card.id}", %{"blank" => %{"1" => "ging"}}) |> render_submit()
      assert has_element?(view, "#card-correct")
      assert Repo.aggregate(Review, :count) == 1
    end

    test "a card you missed before comes back as fill-in-the-blank", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      card |> Ecto.Changeset.change(blank_indices: [1]) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      assert has_element?(view, "#cloze-#{card.id} textarea.cloze-blank[name='blank[1]']")

      view |> form("#cloze-#{card.id}", %{"blank" => %{"1" => "ging"}}) |> render_submit()
      assert_push_event(view, "confetti", %{})
    end

    test "a case-only answer counts as correct but flags the capitalization", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "ich ging nach hause."}) |> render_submit()

      assert_push_event(view, "confetti", %{})
      assert has_element?(view, "[data-role=case-warning] .line-through", "ich")
    end

    test "fix this card edits it in place", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> element("#fix-card") |> render_click()

      view
      |> form("#fix-card-form", %{
        card: %{native_text: "I walked home.", target_text: "Ich lief nach Hause."}
      })
      |> render_submit()

      assert %{native_text: "I walked home.", target_text: "Ich lief nach Hause."} =
               Repo.get(Card, card.id)

      # Still on the prompt, now asking the fixed card.
      assert has_element?(view, "#answer-#{card.id}")
      assert has_element?(view, "#fix-card")
    end

    test "fix this card can delete a bad card, which moves on", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> element("#fix-card") |> render_click()
      view |> element("#delete-card") |> render_click()

      assert Flashcards.list_cards() == []
      assert_redirect(view, ~p"/")
    end
  end

  describe "manage page" do
    test "lists, edits, and deletes cards", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, html} = live(conn, ~p"/flashcards/manage")
      assert html =~ "Ich ging nach Hause."

      # Icon actions: AI suggestion, edit, delete.
      assert has_element?(view, "button[phx-click=ai_improve][phx-value-id='#{card.id}']")

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
