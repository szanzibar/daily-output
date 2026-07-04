defmodule DailyOutputWeb.FlashcardLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Conversations, Flashcards, Journal, Repo, Settings}
  alias DailyOutput.Flashcards.Card

  defp new_card(target, native) do
    {:ok, card} =
      %Card{}
      |> Card.changeset(%{target_text: target, native_text: native, language: "de", state: "new"})
      |> Repo.insert()

    card
  end

  defp set_target(n) do
    {:ok, config} = Settings.ensure_config()
    {:ok, _} = Settings.update_config(config, %{flashcards_per_day: n})
  end

  defp complete_entry_today do
    {:ok, entry} = Journal.create_entry(%{body: "x", language: "de"})
    {:ok, entry} = Journal.save_feedback(entry, %{"annotated_text" => "x"})
    {:ok, _} = Journal.complete_entry(entry)
  end

  defp complete_conversation_today do
    {:ok, convo} = Conversations.create_conversation(%{topic: "x", language: "de"})
    {:ok, convo} = Conversations.save_feedback(convo, %{"annotated_text" => "x"})
    {:ok, _} = Conversations.complete_conversation(convo)
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

    test "shows a goal-complete indicator once the daily target is met", %{conn: conn} do
      set_target(1)
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "Ich ging nach Hause."}) |> render_submit()

      assert Flashcards.today_progress().complete?
      assert has_element?(view, "[data-role=goal-complete]")
    end

    test "celebrates the whole day when flashcards are the finishing task", %{conn: conn} do
      complete_entry_today()
      complete_conversation_today()
      set_target(1)
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "Ich ging nach Hause."}) |> render_submit()

      assert_push_event(view, "celebrate", %{kind: "day"})
    end

    test "the reveal offers an AI translation button", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "falsch"}) |> render_submit()
      assert has_element?(view, "button[phx-click=ai_improve]")
    end

    test "a case-only answer counts as correct but flags the capitalization", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "ich ging nach hause."}) |> render_submit()

      # Treated as a pass (confetti + recorded), with a gentle capitalization nudge that
      # shows the fixes (locale-independent, like the other UI assertions here).
      assert_push_event(view, "confetti", %{})
      assert Flashcards.today_progress().done == 1
      assert has_element?(view, "[data-role=case-warning]")
      assert has_element?(view, "[data-role=case-warning] .line-through", "ich")
    end

    test "a miss narrows the card to fill-in-the-blank on just the wrong word", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      # One word wrong ("ging" → "gehe"): the card's mask narrows to that word.
      view |> form("form", %{answer: "Ich gehe nach Hause."}) |> render_submit()
      assert Repo.get(Card, card.id).blank_indices == [1]

      # Re-drilled this session, it's now a cloze: the right words are shown, the missed
      # one is an inline blank you fill in.
      view |> element("button[phx-click=continue]") |> render_click()
      assert has_element?(view, "textarea.cloze-blank[name='blank[1]']")
      assert render(view) =~ "nach Hause."

      # Filling that blank correctly passes and holds the mask at the same level.
      view |> form("#cloze-#{card.id}", %{"blank" => %{"1" => "ging"}}) |> render_submit()
      assert_push_event(view, "confetti", %{})
      assert Repo.get(Card, card.id).blank_indices == [1]
    end

    test "you can step back through answered cards and resume studying", %{conn: conn} do
      a = new_card("Ich ging nach Hause.", "I went home.")
      b = new_card("Wie geht es dir?", "How are you?")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      # `due_today` shuffles the queue, so either card can be first — answer whichever
      # one is actually shown rather than assuming an order.
      {first, second} = if render(view) =~ a.native_text, do: {a, b}, else: {b, a}

      # Nothing answered yet → no Previous affordance.
      refute has_element?(view, "button[phx-click=prev]")

      # Answer the first card correctly and advance to the second.
      view |> form("form", %{answer: first.target_text}) |> render_submit()
      send(view.pid, :advance_after_correct)
      assert render(view) =~ second.native_text
      assert has_element?(view, "button[phx-click=prev]")

      # Step back: a read-only review of the first card, marked correct.
      html = view |> element("button[phx-click=prev]") |> render_click()
      assert has_element?(view, "[data-role=card-review]")
      assert has_element?(view, "[data-role=review-result][data-result=pass]")
      assert html =~ first.native_text
      assert html =~ first.target_text
      # While looking back, the live card isn't shown.
      refute has_element?(view, "textarea[name=answer]")

      # Step forward past the newest entry → back to the live card.
      view |> element("button[phx-click=next]") |> render_click()
      assert has_element?(view, "textarea[name=answer]")
      assert render(view) =~ second.native_text
    end

    test "a missed card is marked as missed in the history", %{conn: conn} do
      new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "Ich gehe nach Hause."}) |> render_submit()

      # The arrow-key handler pushes the same "prev" event the button does.
      html = render_hook(view, "prev", %{})
      assert has_element?(view, "[data-role=review-result][data-result=fail]")
      # Looking back replays the green/red corrections, not just the plain answer.
      assert html =~ "correction-deleted"
      assert html =~ "correction-added"
    end

    test "editing a card's answer text clears its fill-in-the-blank mask", %{conn: conn} do
      card = new_card("Ich ging nach Hause.", "I went home.")
      {:ok, view, _html} = live(conn, ~p"/flashcards")

      view |> form("form", %{answer: "Ich gehe nach Hause."}) |> render_submit()
      assert Repo.get(Card, card.id).blank_indices == [1]

      view |> element("button[phx-click=edit]") |> render_click()

      view
      |> form("#flashcard-edit-form", %{
        card: %{native_text: "I went home.", target_text: "Ich fuhr nach Hause."}
      })
      |> render_submit()

      assert Repo.get(Card, card.id).blank_indices == nil
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
