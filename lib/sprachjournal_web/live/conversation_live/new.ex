defmodule SprachjournalWeb.ConversationLive.New do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.{Conversations, Settings, AI, FocusTopics}

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()

    {:ok,
     assign(socket,
       page_title: "Neues Gespräch",
       config: config,
       phase: :topics,
       openers: [],
       openers_loading: true,
       conversation: nil,
       messages: [],
       input: "",
       ai_loading: false,
       feedback: nil,
       feedback_loading: false,
       error: nil,
       focus_topics: [],
       selected_focus_topic: nil
     )
     |> then(fn socket ->
       if connected?(socket), do: load_openers(socket), else: socket
     end)}
  end

  defp load_openers(socket) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result =
        AI.generate_openers(
          config.topics || [],
          config.target_language || "de",
          config.native_language || "en"
        )

      send(pid, {:openers_loaded, result})
    end)

    socket
  end

  @impl true
  def handle_info({:openers_loaded, {:ok, openers}}, socket) do
    {:noreply, assign(socket, openers: openers, openers_loading: false)}
  end

  def handle_info({:openers_loaded, {:error, :api_key_not_set}}, socket) do
    {:noreply,
     assign(socket,
       openers: [],
       openers_loading: false,
       error: "ANTHROPIC_API_KEY nicht gesetzt."
     )}
  end

  def handle_info({:openers_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       openers: [],
       openers_loading: false,
       error: "Gesprächseröffnungen konnten nicht geladen werden: #{inspect(reason)}"
     )}
  end

  def handle_info({:ai_response, {:ok, text}}, socket) do
    conversation = socket.assigns.conversation

    case Conversations.add_message(conversation, %{role: "assistant", body: text}) do
      {:ok, msg} ->
        {:noreply,
         assign(socket,
           messages: socket.assigns.messages ++ [msg],
           ai_loading: false
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, ai_loading: false, error: "Antwort konnte nicht gespeichert werden.")}
    end
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    {:noreply, assign(socket, ai_loading: false, error: "KI-Fehler: #{inspect(reason)}")}
  end

  def handle_info({:feedback_loaded, {:ok, feedback}}, socket) do
    conversation = socket.assigns.conversation

    case Conversations.save_feedback(conversation, feedback) do
      {:ok, conversation} ->
        {:noreply, push_navigate(socket, to: ~p"/conversations/#{conversation.id}")}

      {:error, _} ->
        {:noreply, assign(socket, feedback: feedback, feedback_loading: false)}
    end
  end

  def handle_info({:feedback_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: "Feedback konnte nicht geladen werden: #{inspect(reason)}"
     )}
  end

  @impl true
  def handle_event("select_opener", %{"opener" => opener}, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      start_conversation(socket, opener, :ai_opens)
    else
      {:noreply,
       assign(socket,
         phase: :focus_topic,
         focus_topics: topics,
         pending_opener: opener,
         pending_mode: :ai_opens
       )}
    end
  end

  def handle_event("freestyle", %{"topic" => topic}, socket) do
    topic = String.trim(topic)
    {opener, mode} = if topic == "", do: {nil, :empty}, else: {topic, :user_opens}
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      start_conversation(socket, opener, mode)
    else
      {:noreply,
       assign(socket,
         phase: :focus_topic,
         focus_topics: topics,
         pending_opener: opener,
         pending_mode: mode
       )}
    end
  end

  def handle_event("select_focus_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    socket = assign(socket, selected_focus_topic: topic)
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode)
  end

  def handle_event("skip_focus_topic", _params, socket) do
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode)
  end

  def handle_event("add_focus_topic", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("master_focus_topic", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("override_focus_result", _params, socket) do
    {:noreply, socket}
  end

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

    # Join user messages with a separator so we can split them back after proofreading
    user_text =
      messages
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.map(& &1.body)
      |> Enum.join("\n---MSG_BREAK---\n")

    socket = assign(socket, conversation: conversation, phase: :feedback, feedback_loading: true)

    pid = self()

    Task.start(fn ->
      result =
        AI.proofread(user_text,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || "",
          focus_topic:
            socket.assigns.selected_focus_topic && socket.assigns.selected_focus_topic.text
        )

      send(pid, {:feedback_loaded, result})
    end)

    {:noreply, socket}
  end

  defp start_conversation(socket, topic, mode) do
    config = socket.assigns.config

    focus_topic = socket.assigns.selected_focus_topic

    case Conversations.create_conversation(%{
           topic: topic,
           language: config.target_language || "de",
           focus_topic_id: focus_topic && focus_topic.id
         }) do
      {:ok, conversation} ->
        socket = assign(socket, conversation: conversation, phase: :chat, messages: [])

        case mode do
          :ai_opens ->
            # AI opens with the selected opener
            case Conversations.add_message(conversation, %{role: "assistant", body: topic}) do
              {:ok, msg} ->
                {:noreply, assign(socket, messages: [msg])}

              {:error, _} ->
                {:noreply, socket}
            end

          :user_opens ->
            # User's freestyle text is their first message, AI responds
            case Conversations.add_message(conversation, %{role: "user", body: topic}) do
              {:ok, msg} ->
                messages = [msg]
                socket = assign(socket, messages: messages, ai_loading: true)
                request_ai_response(socket, messages)

              {:error, _} ->
                {:noreply, socket}
            end

          :empty ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Gespräch konnte nicht erstellt werden.")}
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
    <div class="max-w-4xl mx-auto">
      <%!-- PHASE: Topic Selection --%>
      <div :if={@phase == :topics} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          Gespräch
        </h1>

        <hr class="brutal-hr" />

        <.retro_loader :if={@openers_loading} message="Gesprächseröffnungen werden geladen" />

        <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>

        <div :if={!@openers_loading} class="grid gap-3">
          <button
            :for={opener <- @openers}
            phx-click="select_opener"
            phx-value-opener={opener["opener"]}
            class="brutal-btn text-left p-4 bg-base-100 hover:bg-base-200 w-full"
          >
            <div class="font-bold text-base">{opener["opener"]}</div>
            <div class="text-xs text-base-content/60 mt-1 font-mono">{opener["translation"]}</div>
          </button>

          <form phx-submit="freestyle" class="brutal-btn p-4 block-yellow text-left w-full">
            <div class="font-bold text-base">Freestyle</div>
            <div class="text-xs opacity-70 mb-2 font-mono">
              Schreib den ersten Satz — dein Partner antwortet darauf
            </div>
            <div class="flex gap-2">
              <input
                type="text"
                name="topic"
                placeholder="z.B. Ich habe gestern einen tollen Film gesehen!"
                class="input border-3 border-ink flex-1 font-mono text-sm"
              />
              <button type="submit" class="brutal-btn px-4 py-2 bg-ink text-paper text-sm">
                Los
              </button>
            </div>
          </form>
        </div>
      </div>

      <%!-- PHASE: Focus Topic Selection --%>
      <div :if={@phase == :focus_topic} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          Fokus wählen
        </h1>

        <hr class="brutal-hr" />

        <p class="text-sm font-mono text-base-content/60">
          Wähle ein Thema aus deinem Fokus-Pool, auf das du dich konzentrieren willst.
        </p>

        <div class="grid gap-3">
          <button
            :for={topic <- @focus_topics}
            phx-click="select_focus_topic"
            phx-value-id={topic.id}
            class="brutal-btn text-left p-4 bg-base-100 hover:bg-base-200 w-full"
          >
            <div class="text-sm normal-case">{topic.text}</div>
          </button>

          <button
            phx-click="skip_focus_topic"
            class="brutal-btn p-4 bg-base-200 text-left w-full"
          >
            <div class="font-bold text-base">Überspringen</div>
            <div class="text-xs opacity-70 mt-1 font-mono">Ohne Fokus-Thema sprechen</div>
          </button>
        </div>
      </div>

      <%!-- PHASE: Chat --%>
      <div :if={@phase == :chat} class="space-y-4">
        <%!-- Focus topic reminder --%>
        <div :if={@selected_focus_topic} class="border-4 border-ink p-3 block-blue">
          <span class="text-xs font-mono uppercase tracking-widest">Fokus:</span>
          <span class="text-sm ml-2">{@selected_focus_topic.text}</span>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
            Gespräch
          </h1>
          <div class="flex items-center gap-3">
            <span class="text-xs font-mono text-base-content/60">
              {user_count(@messages)}/{@config.min_exchanges || 5} Austausche
            </span>
            <button
              :if={user_count(@messages) >= (@config.min_exchanges || 5)}
              phx-click="complete"
              class="brutal-btn px-4 py-2 block-green text-sm"
            >
              Fertig &check;
            </button>
          </div>
        </div>

        <hr class="brutal-hr" />

        <.chat_history messages={@messages} />

        <div :if={@ai_loading} class="chat-bubble-row chat-ai">
          <div class="chat-role">Partner</div>
          <div class="chat-bubble chat-bubble-ai">
            <span class="animate-pulse font-mono">...</span>
          </div>
        </div>

        <form :if={!@ai_loading} phx-submit="send" class="flex items-end gap-2">
          <textarea
            id="chat-input"
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

        <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>
      </div>

      <%!-- PHASE: Feedback --%>
      <div :if={@phase == :feedback}>
        <.loading :if={@feedback_loading} title="Feedback" message="Dein Gespräch wird geprüft" />

        <div :if={@feedback && !@feedback_loading} class="space-y-6">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            Feedback
          </h1>
          <hr class="brutal-hr" />

          <div :if={@feedback["encouragement"]} class="border-4 border-ink p-5 block-yellow">
            <p class="font-bold text-base">{@feedback["encouragement"]}</p>
          </div>

          <.chat_feedback messages={@messages} feedback={@feedback} />

          <%!-- Commentary / Tipps --%>
          <div :if={(@feedback["commentary"] || []) != []} class="border-4 border-ink p-5">
            <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
              <span class="inline-block w-3 h-3 block-blue"></span> Tipps
            </h2>
            <div :for={item <- @feedback["commentary"] || []} class="mb-3 last:mb-0">
              <span class="text-xs font-mono uppercase px-2 py-0.5 border-2 border-ink mr-2">
                {item["type"]}
              </span>
              <span class="text-sm">{item["text"]}</span>
            </div>
          </div>

          <.link
            navigate={~p"/"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            Zurück
          </.link>
        </div>

        <div :if={@error && !@feedback_loading && !@feedback} class="space-y-6">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">Feedback</h1>
          <hr class="brutal-hr" />
          <div class="border-4 border-ink p-5 block-red">
            <p class="font-mono text-sm">{@error}</p>
          </div>
          <.link
            navigate={~p"/"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            Zurück
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
