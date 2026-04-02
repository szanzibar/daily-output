defmodule DailyOutputWeb.ConversationComponents do
  @moduledoc """
  Chat bubble components for conversations.
  """
  use Phoenix.Component
  use Gettext, backend: DailyOutputWeb.Gettext

  attr :messages, :list, required: true

  def chat_history(assigns) do
    ~H"""
    <div class="chat-history space-y-3">
      <.chat_bubble :for={msg <- @messages} message={msg} />
    </div>
    """
  end

  attr :message, :map, required: true

  def chat_bubble(assigns) do
    ~H"""
    <div class={["chat-bubble-row", if(@message.role == "user", do: "chat-user", else: "chat-ai")]}>
      <div class="chat-role">
        {if @message.role == "user", do: gettext("You"), else: gettext("Partner")}
      </div>
      <div class={[
        "chat-bubble",
        if(@message.role == "user", do: "chat-bubble-user", else: "chat-bubble-ai")
      ]}>
        {@message.body}
      </div>
    </div>
    """
  end

  @doc """
  Renders the conversation feedback as an interleaved chat with corrections on user messages.
  AI messages shown as-is. User messages get inline corrections via the AnnotatedText JS hook.
  The annotated_text is split by ---MSG_BREAK--- to map back to individual user messages.
  """
  attr :messages, :list, required: true
  attr :feedback, :map, required: true

  def chat_feedback(assigns) do
    annotated_text = assigns.feedback["annotated_text"] || ""
    annotations = assigns.feedback["annotations"] || []

    # Split annotated text by our separator to get per-user-message chunks
    user_chunks =
      annotated_text
      |> String.split("---MSG_BREAK---")
      |> Enum.map(&String.trim/1)

    # Build interleaved conversation: pair user messages with their annotated chunks
    user_messages =
      assigns.messages
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.with_index()

    user_chunk_map =
      Enum.zip(user_messages, user_chunks ++ List.duplicate("", 20))
      |> Enum.into(%{}, fn {{_msg, idx}, chunk} -> {idx, chunk} end)

    # Build display items in conversation order
    {items, _user_idx} =
      Enum.reduce(assigns.messages, {[], 0}, fn msg, {items, ui} ->
        if msg.role == "user" do
          chunk = Map.get(user_chunk_map, ui, msg.body)
          item = %{type: :user, body: msg.body, annotated: chunk, index: ui}
          {items ++ [item], ui + 1}
        else
          item = %{type: :ai, body: msg.body}
          {items ++ [item], ui}
        end
      end)

    annotations_json = Jason.encode!(annotations)

    assigns = assign(assigns, items: items, annotations_json: annotations_json)

    ~H"""
    <div class="space-y-3">
      <%= for item <- @items do %>
        <%= if item.type == :ai do %>
          <div class="chat-bubble-row chat-ai">
            <div class="chat-role">{gettext("Partner")}</div>
            <div class="chat-bubble chat-bubble-ai">{item.body}</div>
          </div>
        <% else %>
          <div class="chat-bubble-row">
            <div class="chat-role" style="text-align:right">{gettext("You")}</div>
            <div class="chat-bubble-user-feedback">
              <div
                id={"annotated-msg-#{item.index}"}
                phx-hook="AnnotatedText"
                class="annotated-text"
                data-annotated-text={item.annotated}
                data-annotations={@annotations_json}
              >
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
