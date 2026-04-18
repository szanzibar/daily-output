defmodule DailyOutputWeb.ConversationLive.New do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Conversations, Settings, AI, FocusTopics}

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()

    {:ok,
     assign(socket,
       page_title: gettext("New Conversation"),
       config: config,
       phase: :topics,
       openers: [],
       openers_loading: true,
       error: nil,
       focus_topics: [],
       pending_opener: nil,
       pending_mode: :empty
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
       error: DailyOutput.AI.api_key_error_message()
     )}
  end

  def handle_info({:openers_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       openers: [],
       openers_loading: false,
       error: gettext("Could not load conversation openers: %{reason}", reason: inspect(reason))
     )}
  end

  @impl true
  def handle_event("select_opener", %{"opener" => opener}, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      start_conversation(socket, opener, :ai_opens, nil)
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
      start_conversation(socket, opener, mode, nil)
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
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode, topic)
  end

  def handle_event("skip_focus_topic", _params, socket) do
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode, nil)
  end

  defp start_conversation(socket, topic, mode, focus_topic) do
    config = socket.assigns.config

    with {:ok, conversation} <-
           Conversations.create_conversation(%{
             topic: topic,
             language: config.target_language || "de",
             focus_topic_id: focus_topic && focus_topic.id
           }),
         :ok <- seed_initial_messages(conversation, topic, mode) do
      {:noreply, push_navigate(socket, to: ~p"/conversations/#{conversation.id}/continue")}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start conversation."))}
    end
  end

  defp seed_initial_messages(_conversation, topic, :ai_opens)
       when not is_binary(topic) or topic == "",
       do: :ok

  defp seed_initial_messages(conversation, topic, :ai_opens) do
    case Conversations.add_message(conversation, %{role: "assistant", body: topic}) do
      {:ok, _msg} -> :ok
      {:error, _} -> {:error, :failed_to_seed}
    end
  end

  defp seed_initial_messages(_conversation, topic, :user_opens)
       when not is_binary(topic) or topic == "",
       do: :ok

  defp seed_initial_messages(conversation, topic, :user_opens) do
    case Conversations.add_message(conversation, %{role: "user", body: topic}) do
      {:ok, _msg} -> :ok
      {:error, _} -> {:error, :failed_to_seed}
    end
  end

  defp seed_initial_messages(_conversation, _topic, :empty), do: :ok
  defp seed_initial_messages(_conversation, _topic, _mode), do: :ok

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <%!-- PHASE: Topic Selection --%>
      <div :if={@phase == :topics} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          {gettext("Conversation")}
        </h1>

        <hr class="brutal-hr" />

        <.retro_loader :if={@openers_loading} message={gettext("Loading conversation openers")} />

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
            <div class="font-bold text-base">{gettext("Freestyle")}</div>
            <div class="text-xs opacity-70 mb-2 font-mono">
              {gettext("Write the first sentence — your partner will respond")}
            </div>
            <div class="flex gap-2">
              <input
                type="text"
                name="topic"
                placeholder="z.B. Ich habe gestern einen tollen Film gesehen!"
                class="input border-3 border-ink flex-1 font-mono text-sm"
              />
              <button type="submit" class="brutal-btn px-4 py-2 bg-ink text-paper text-sm">
                {gettext("Go")}
              </button>
            </div>
          </form>
        </div>
      </div>

      <%!-- PHASE: Focus Topic Selection --%>
      <div :if={@phase == :focus_topic} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          {gettext("Choose Focus")}
        </h1>

        <hr class="brutal-hr" />

        <p class="text-sm font-mono text-base-content/60">
          {gettext("Choose a topic from your focus pool to concentrate on.")}
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
            <div class="font-bold text-base">{gettext("Skip")}</div>
            <div class="text-xs opacity-70 mt-1 font-mono">
              {gettext("Speak without a focus topic")}
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
