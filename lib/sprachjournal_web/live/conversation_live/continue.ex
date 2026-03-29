defmodule SprachjournalWeb.ConversationLive.Continue do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.{Conversations, Settings, AI}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    original = Conversations.get_conversation!(id)
    config = Settings.get_config()

    # If it has feedback, branch into a new conversation with the same messages
    {conversation, messages} =
      if original.feedback do
        {:ok, new_convo} =
          Conversations.create_conversation(%{
            topic: original.topic,
            language: original.language
          })

        # Copy all messages to the new conversation
        msgs =
          Enum.map(original.messages, fn msg ->
            {:ok, new_msg} =
              Conversations.add_message(new_convo, %{role: msg.role, body: msg.body})

            new_msg
          end)

        {new_convo, msgs}
      else
        {original, original.messages}
      end

    {:ok,
     assign(socket,
       page_title: "Gespräch fortsetzen",
       config: config,
       conversation: conversation,
       messages: messages,
       input: "",
       ai_loading: false,
       feedback: nil,
       feedback_loading: false,
       error: nil
     )}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation

      case Conversations.add_message(conversation, %{role: "user", body: message}) do
        {:ok, msg} ->
          messages = socket.assigns.messages ++ [msg]
          socket = assign(socket, messages: messages, input: "", ai_loading: true)
          request_ai_response(socket, messages)

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Nachricht konnte nicht gespeichert werden.")}
      end
    end
  end

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  def handle_event("complete", _params, socket) do
    conversation = socket.assigns.conversation
    config = socket.assigns.config
    messages = socket.assigns.messages

    {:ok, conversation} = Conversations.complete_conversation(conversation)

    user_text =
      messages
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.map(& &1.body)
      |> Enum.join("\n---MSG_BREAK---\n")

    socket = assign(socket, conversation: conversation, feedback_loading: true)

    pid = self()

    Task.start(fn ->
      result =
        AI.proofread(user_text,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || ""
        )

      send(pid, {:feedback_loaded, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ai_response, {:ok, text}}, socket) do
    case Conversations.add_message(socket.assigns.conversation, %{role: "assistant", body: text}) do
      {:ok, msg} ->
        {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], ai_loading: false)}

      {:error, _} ->
        {:noreply,
         assign(socket, ai_loading: false, error: "Antwort konnte nicht gespeichert werden.")}
    end
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    {:noreply, assign(socket, ai_loading: false, error: "KI-Fehler: #{inspect(reason)}")}
  end

  def handle_info({:feedback_loaded, {:ok, feedback}}, socket) do
    case Conversations.save_feedback(socket.assigns.conversation, feedback) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Feedback erhalten!")
         |> push_navigate(to: ~p"/conversations/#{conversation.id}")}

      {:error, _} ->
        {:noreply,
         assign(socket,
           feedback_loading: false,
           error: "Feedback konnte nicht gespeichert werden."
         )}
    end
  end

  def handle_info({:feedback_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: "Feedback konnte nicht geladen werden: #{inspect(reason)}"
     )}
  end

  defp request_ai_response(socket, messages) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result =
        AI.conversation_respond(messages,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || ""
        )

      send(pid, {:ai_response, result})
    end)

    {:noreply, socket}
  end

  defp user_count(messages) do
    Enum.count(messages, &(&1.role == "user"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
          Gespräch fortsetzen
        </h1>
        <div class="flex items-center gap-3">
          <span class="text-xs font-mono text-base-content/60">
            {user_count(@messages)}/{@config.min_exchanges || 5} Austausche
          </span>
          <button
            :if={user_count(@messages) >= (@config.min_exchanges || 5) && !@feedback_loading}
            phx-click="complete"
            class="brutal-btn px-4 py-2 block-green text-sm"
          >
            Fertig &check;
          </button>
        </div>
      </div>

      <hr class="brutal-hr" />

      <.retro_loader :if={@feedback_loading} message="Dein Gespräch wird geprüft" />

      <div :if={!@feedback_loading}>
        <.chat_history messages={@messages} />

        <div :if={@ai_loading} class="chat-bubble-row chat-ai mt-3">
          <div class="chat-role">Partner</div>
          <div class="chat-bubble chat-bubble-ai">
            <span class="animate-pulse font-mono">...</span>
          </div>
        </div>

        <form :if={!@ai_loading} phx-submit="send" class="flex items-end gap-2 mt-3">
          <textarea
            id="chat-input-continue"
            phx-hook="AutoExpand"
            phx-mounted={JS.focus()}
            name="message"
            rows="1"
            placeholder="Schreib eine Nachricht..."
            class="chat-input flex-1"
          >{@input}</textarea>
          <button type="submit" class="brutal-btn px-6 py-3 block-blue text-lg shrink-0">
            &rarr;
          </button>
        </form>
      </div>

      <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>
    </div>
    """
  end
end
