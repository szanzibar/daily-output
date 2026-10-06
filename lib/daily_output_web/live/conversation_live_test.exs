defmodule DailyOutputWeb.ConversationLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock}

  @focus %{"category" => "verb", "title" => "Perfekt mit sein", "body" => "Bewegung: sein."}
  # No corrections, so finishing never asks the AI for flashcards.
  @clean %{"annotated_text" => "Gut.", "annotations" => []}

  defp conversation(messages \\ []) do
    activity =
      Activities.create(%{kind: "conversation", prompt: "Hoi! Wie gehts?", focus: @focus})

    for {role, body} <- messages do
      message = Activities.add_message(activity, role, body)
      if role == "user", do: Activities.save_message_feedback(message, @clean)
    end

    activity
  end

  test "prepares the focus and opener behind a loading state", %{conn: conn} do
    activity =
      Activities.create(%{kind: "conversation", angle: "story", focus: %{"category" => nil}})

    test = self()

    expect_ai(1, fn _body ->
      send(test, {:writing, self()})
      receive do: (:go -> @focus)
    end)

    expect_ai("Hoi! Was hast du heute vor?")

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    assert_receive {:writing, task}
    assert has_element?(view, "#prepare-loading")
    refute has_element?(view, "#chat-form")

    send(task, :go)
    render_async(view)

    assert has_element?(view, "#focus-banner", "Perfekt mit sein")
    assert has_element?(view, "#opener", "Hoi! Was hast du heute vor?")
    assert has_element?(view, "#chat-input[data-persist-key='chat-#{activity.id}']")
  end

  test "a failed prepare shows one error state, and retry recovers", %{conn: conn} do
    activity =
      Activities.create(%{kind: "conversation", angle: "story", focus: %{"category" => nil}})

    Req.Test.expect(DailyOutput.AI, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{"message" => "Invalid request.", "type" => "invalid_request_error"}
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    render_async(view)
    assert has_element?(view, "#prepare-error")

    expect_ai(@focus)
    expect_ai("Hoi!")
    view |> element("#prepare-error button") |> render_click()
    render_async(view)

    refute has_element?(view, "#prepare-error")
    assert has_element?(view, "#opener", "Hoi!")
  end

  test "a turn is saved, then corrected and answered in parallel", %{conn: conn} do
    activity = conversation()

    expect_ai(2, fn body ->
      if body["tools"],
        do: %{"corrected" => "Mir geht es gut.", "corrections" => []},
        else: "Schön! Was machst du heute?"
    end)

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    view |> form("#chat-form", message: "Mir geht es gut.") |> render_submit()

    assert [%{role: "user", body: "Mir geht es gut."} = sent] =
             Activities.get!(activity.id).messages

    assert has_element?(view, "#message-#{sent.id}")

    render_async(view)

    [sent, reply] = Activities.get!(activity.id).messages
    assert has_element?(view, "#correction-#{sent.id}")
    assert has_element?(view, "#message-#{reply.id}", "Schön! Was machst du heute?")
    assert has_element?(view, "#chat-form")
  end

  test "the 5th message ends the conversation, then the results load", %{conn: conn} do
    activity =
      conversation(
        Enum.flat_map(1..4, &[{"user", "Nachricht #{&1}"}, {"assistant", "Antwort #{&1}"}])
      )

    expect_ai(3, fn body ->
      cond do
        Jason.encode!(body["tools"]) =~ "focus_result" ->
          %{
            "summary" => "You talked about your day.",
            "focus_result" => %{"used" => true, "correct" => true, "comment" => "Gut gemacht."}
          }

        body["tools"] ->
          %{"corrected" => "Tschüss!", "corrections" => []}

        true ->
          "Schön, bis bald!"
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    view |> form("#chat-form", message: "Tschüss!") |> render_submit()
    refute has_element?(view, "#chat-form")

    # The correction and the reply land, then the finish starts.
    render_async(view)
    render_async(view)

    assert Activities.get!(activity.id).completed_at
    assert has_element?(view, "#results #focus-result")
    assert has_element?(view, "#results #improvement")
    assert has_element?(view, "#continue[href='/']")
    refute has_element?(view, "#chat-form")
  end

  test "resuming with your message last asks for the reply", %{conn: conn} do
    activity = conversation([{"user", "Gut, danke!"}])
    expect_ai("Super! Und sonst?")

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    assert has_element?(view, "#partner-typing")
    refute has_element?(view, "#chat-form")

    render_async(view)

    assert [_, reply] = Activities.get!(activity.id).messages
    assert has_element?(view, "#message-#{reply.id}", "Super! Und sonst?")
    assert has_element?(view, "#chat-form")
  end

  test "an earlier day's conversation reads as results only", %{conn: conn} do
    activity =
      Activities.create(%{
        kind: "conversation",
        date: Date.add(Clock.today(), -3),
        prompt: "Hoi!",
        focus: @focus,
        feedback: %{"focus_result" => %{"used" => false}, "improvement" => %{}},
        completed_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")

    assert has_element?(view, "#results #focus-result")
    assert has_element?(view, "#back-to-history")
    refute has_element?(view, "#continue")
    refute has_element?(view, "#chat-form")
  end
end
