defmodule SprachjournalWeb.ConversationComponents do
  @moduledoc """
  Chat bubble components for conversations.
  """
  use Phoenix.Component

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
        {if @message.role == "user", do: "Du", else: "Partner"}
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

  attr :messages, :list, required: true
  attr :feedback, :map, required: true

  def chat_feedback(assigns) do
    annotations_json = Jason.encode!(assigns.feedback["annotations"] || [])

    # Build the annotated conversation: AI messages shown as-is, user messages annotated
    user_texts =
      assigns.messages
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.map(& &1.body)
      |> Enum.join("\n\n")

    assigns =
      assign(assigns,
        annotations_json: annotations_json,
        user_texts: user_texts
      )

    ~H"""
    <div class="space-y-3">
      <%= for msg <- @messages do %>
        <div class={[
          "chat-bubble-row",
          if(msg.role == "user", do: "chat-user", else: "chat-ai")
        ]}>
          <div class="chat-role">
            {if msg.role == "user", do: "Du", else: "Partner"}
          </div>
          <div class={[
            "chat-bubble",
            if(msg.role == "user", do: "chat-bubble-user", else: "chat-bubble-ai")
          ]}>
            {msg.body}
          </div>
        </div>
      <% end %>
    </div>

    <%!-- Inline corrections on user messages only --%>
    <div class="mt-6 border-4 border-ink p-4">
      <h2 class="text-lg font-black uppercase mb-4 flex items-center gap-2">
        <span class="inline-block w-3 h-3 block-red"></span> Korrekturen
      </h2>
      <div
        id="annotated-text"
        phx-hook="AnnotatedText"
        class="annotated-text"
        data-annotated-text={@feedback["annotated_text"] || ""}
        data-annotations={@annotations_json}
      >
      </div>
    </div>
    """
  end
end
