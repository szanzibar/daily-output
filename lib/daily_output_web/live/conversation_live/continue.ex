defmodule DailyOutputWeb.ConversationLive.Continue do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Conversations, Settings, AI, FocusTopics}

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
            language: original.language,
            focus_topic_id: original.focus_topic_id
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

    socket =
      assign(socket,
        page_title: gettext("Continue Conversation"),
        config: config,
        conversation: conversation,
        messages: messages,
        focus_topic_text:
          if conversation.focus_topic_id do
            FocusTopics.get_topic!(conversation.focus_topic_id).text
          end,
        input: "",
        ai_loading: false,
        feedback: nil,
        feedback_loading: false,
        error: nil
      )

    socket =
      if connected?(socket) and match?(%{role: "user"}, List.last(messages)) do
        send(self(), :request_ai_reply)
        assign(socket, ai_loading: true)
      else
        socket
      end

    {:ok, socket}
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
          {:noreply, put_flash(socket, :error, gettext("Could not save message."))}
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
          prompt_context: config.prompt_context || "",
          focus_topic: socket.assigns.focus_topic_text
        )

      send(pid, {:feedback_loaded, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:request_ai_reply, socket) do
    request_ai_response(socket, socket.assigns.messages)
  end

  def handle_info({:ai_response, {:ok, text}}, socket) do
    case Conversations.add_message(socket.assigns.conversation, %{role: "assistant", body: text}) do
      {:ok, msg} ->
        {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], ai_loading: false)}

      {:error, _} ->
        {:noreply, assign(socket, ai_loading: false, error: gettext("Could not save response."))}
    end
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       ai_loading: false,
       error: gettext("AI error: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_info({:feedback_loaded, {:ok, feedback}}, socket) do
    case Conversations.save_feedback(socket.assigns.conversation, feedback) do
      {:ok, conversation} ->
        if should_complete_conversation?(conversation) do
          case Conversations.complete_conversation(conversation) do
            {:ok, completed_conversation} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Feedback received!"))
               |> push_navigate(to: ~p"/conversations/#{completed_conversation.id}")}

            {:error, _changeset} ->
              {:noreply,
               assign(socket,
                 feedback_loading: false,
                 error: gettext("Could not complete conversation.")
               )}
          end
        else
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Focus topic not used yet. Continue and resubmit to complete the day.")
           )
           |> push_navigate(to: ~p"/conversations/#{conversation.id}")}
        end

      {:error, _} ->
        {:noreply,
         assign(socket,
           feedback_loading: false,
           error: gettext("Could not save feedback.")
         )}
    end
  end

  def handle_info({:feedback_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: gettext("Could not load feedback: %{reason}", reason: inspect(reason))
     )}
  end

  defp should_complete_conversation?(conversation) do
    if is_nil(conversation.focus_topic_id) do
      true
    else
      case conversation.feedback do
        %{"focus_result" => %{} = focus_result} ->
          Map.get(focus_result, "used") == true

        _ ->
          false
      end
    end
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
      <div :if={@focus_topic_text} class="border-4 border-ink p-3 block-blue">
        <span class="text-xs font-mono uppercase tracking-widest">{gettext("Focus:")}</span>
        <span class="text-sm ml-2">{@focus_topic_text}</span>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
          {gettext("Continue Conversation")}
        </h1>
        <div class="flex items-center gap-3">
          <span class="text-xs font-mono text-base-content/60">
            {gettext("%{count}/%{min} exchanges",
              count: user_count(@messages),
              min: @config.min_exchanges || 5
            )}
          </span>
          <button
            :if={user_count(@messages) >= (@config.min_exchanges || 5) && !@feedback_loading}
            phx-click="complete"
            class="brutal-btn px-4 py-2 block-green text-sm"
          >
            {gettext("Done")} &check;
          </button>
        </div>
      </div>

      <hr class="brutal-hr" />

      <.retro_loader :if={@feedback_loading} message={gettext("Your conversation is being reviewed")} />

      <div :if={!@feedback_loading}>
        <.chat_history messages={@messages} />

        <div :if={@ai_loading} class="chat-bubble-row chat-ai mt-3">
          <div class="chat-role">{gettext("Partner")}</div>
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
            placeholder={gettext("Write a message...")}
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
