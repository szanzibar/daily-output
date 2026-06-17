defmodule DailyOutputWeb.ConversationLive.NewTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Conversations, FocusTopics}

  test "creates a persisted conversation with focus and navigates to continue", %{conn: conn} do
    focus_topic =
      create_focus_topic!(%{
        text: "Practice adjective endings",
        source_type: "conversation"
      })

    opener = "Hoi zame, wie laeuft din Tag?"

    {:ok, view, _html} = live(conn, ~p"/conversations/new")

    render_click(view, "select_opener", %{"opener" => opener})

    assert has_element?(
             view,
             ~s(button[phx-click="select_focus_topic"][phx-value-id="#{focus_topic.id}"])
           )

    render_click(view, "select_focus_topic", %{"id" => Integer.to_string(focus_topic.id)})

    {path, _flash} = assert_redirect(view)
    [_, id] = Regex.run(~r|^/conversations/(\d+)/continue$|, path)

    conversation = Conversations.get_conversation!(String.to_integer(id))

    assert conversation.topic == opener
    assert conversation.focus_topic_id == focus_topic.id
    assert Enum.map(conversation.messages, &{&1.role, &1.body}) == [{"assistant", opener}]

    {:ok, continue_view, _html} = live(conn, path)
    assert has_element?(continue_view, "div.block-blue .rich-text", focus_topic.text)

    user_message = "Ich habe heute einen langen Spaziergang gemacht."
    render_submit(continue_view, "send", %{"message" => user_message})

    reloaded = Conversations.get_conversation!(conversation.id)

    assert Enum.any?(
             reloaded.messages,
             &(&1.role == "user" and &1.body == user_message)
           )

    {:ok, resumed_continue_view, _html} = live(conn, path)
    assert has_element?(resumed_continue_view, "div.block-blue .rich-text", focus_topic.text)
    assert has_element?(resumed_continue_view, ".chat-bubble", user_message)
  end

  test "first_message seeds a user opener for the partner to reply to", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/conversations/new")

    render_submit(view, "first_message", %{"message" => "Ich war heute im Park."})

    {path, _flash} = assert_redirect(view)
    [_, id] = Regex.run(~r|^/conversations/(\d+)/continue$|, path)
    conversation = Conversations.get_conversation!(String.to_integer(id))

    assert conversation.topic == "Ich war heute im Park."

    assert Enum.map(conversation.messages, &{&1.role, &1.body}) ==
             [{"user", "Ich war heute im Park."}]
  end

  test "open_topic starts an empty conversation the partner will open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/conversations/new")

    render_submit(view, "open_topic", %{"topic" => "travel plans"})

    {path, _flash} = assert_redirect(view)
    [_, id] = Regex.run(~r|^/conversations/(\d+)/continue$|, path)
    conversation = Conversations.get_conversation!(String.to_integer(id))

    assert conversation.topic == "travel plans"
    assert conversation.messages == []
  end

  defp create_focus_topic!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      text: "Focus #{unique}",
      source_text: "source-#{unique}",
      source_type: "conversation",
      source_id: unique
    }

    {:ok, topic} = FocusTopics.create_topic(Map.merge(defaults, attrs))
    topic
  end
end
