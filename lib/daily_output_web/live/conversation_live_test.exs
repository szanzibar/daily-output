defmodule DailyOutputWeb.ConversationLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Activities, Clock, Today}

  @focus %{"category" => "verb", "title" => "Perfekt mit sein", "body" => "Bewegung: sein."}
  # No corrections, so finishing never asks the AI for flashcards.
  @clean %{"annotated_text" => "Gut."}

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

    test = self()

    expect_ai(1, fn _body ->
      send(test, {:writing, self()})
      receive do: (:go -> @focus)
    end)

    expect_ai("Hoi!")
    view |> element("#prepare-error button") |> render_click()
    assert_receive {:writing, task}
    assert has_element?(view, "#prepare-loading")

    send(task, :go)
    render_async(view)

    refute has_element?(view, "#prepare-error")
    assert has_element?(view, "#opener", "Hoi!")
  end

  test "without an API key, the error names the env var and offers no retry", %{conn: conn} do
    on_exit(fn -> Application.put_env(:daily_output, :openai_api_key, "test") end)
    Application.put_env(:daily_output, :openai_api_key, "")

    activity =
      Activities.create(%{kind: "conversation", angle: "story", focus: %{"category" => nil}})

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    render_async(view)

    assert has_element?(view, "#prepare-error-missing-key", "OPENAI_API_KEY")
    assert has_element?(view, "#prepare-error-missing-key a[href='/settings']")
    refute has_element?(view, "#prepare-error button")
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
    # The input comes back focused, so you can keep typing.
    assert has_element?(view, "#chat-input[phx-mounted]")
  end

  test "a quiet counter shows your messages out of the limit", %{conn: conn} do
    activity = conversation([{"user", "Gut."}, {"assistant", "Und du?"}])

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    assert has_element?(view, "#message-counter", "1 / #{Today.message_limit()}")
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

  test "partner texts translate on demand, and only the first tap asks the AI", %{conn: conn} do
    activity = conversation([{"user", "Gut."}, {"assistant", "Und du?"}])
    [mine, partner] = Activities.get!(activity.id).messages
    test = self()

    expect_ai(1, fn _body ->
      send(test, {:translating, self()})
      receive do: (:go -> "Hi! How are you?")
    end)

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    assert has_element?(view, "#message-#{partner.id} #translate-#{partner.id}-button")
    refute has_element?(view, "#message-#{mine.id} button")

    view |> element("#translate-opener-button") |> render_click()
    assert_receive {:translating, task}
    assert has_element?(view, "#translate-opener-loading")

    send(task, :go)
    render_async(view)
    assert has_element?(view, "#translate-opener-text", "Hi! How are you?")

    view |> element("#translate-opener-button") |> render_click()
    refute has_element?(view, "#translate-opener-text")

    view |> element("#translate-opener-button") |> render_click()
    assert has_element?(view, "#translate-opener-text", "Hi! How are you?")
    assert_received {:ai_request, _}
    refute_received {:ai_request, _}

    # The page re-renders as your next message is corrected and answered.
    expect_ai(2, fn body ->
      if body["tools"], do: %{"corrected" => "Gut.", "corrections" => []}, else: "Schön!"
    end)

    view |> form("#chat-form", message: "Gut.") |> render_submit()
    render_async(view)
    assert has_element?(view, "#translate-opener-text", "Hi! How are you?")
  end

  test "a failed translation offers a retry", %{conn: conn} do
    activity = conversation([{"user", "Gut."}, {"assistant", "Und du?"}])
    [_mine, partner] = Activities.get!(activity.id).messages

    Req.Test.expect(DailyOutput.AI, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{"message" => "Invalid request.", "type" => "invalid_request_error"}
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/conversation/#{activity.id}")
    view |> element("#translate-#{partner.id}-button") |> render_click()
    render_async(view)
    assert has_element?(view, "#translate-#{partner.id}-error")

    expect_ai("And you?")
    view |> element("#translate-#{partner.id}-error button") |> render_click()
    render_async(view)

    refute has_element?(view, "#translate-#{partner.id}-error")
    assert has_element?(view, "#translate-#{partner.id}-text", "And you?")
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
