defmodule DailyOutputWeb.ConversationLive.New do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Conversations, Settings, AI, FocusTopics}

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()
    openers = AI.cached_openers(config.topics || [], target(config), native(config))

    {:ok,
     assign(socket,
       page_title: gettext("New Conversation"),
       config: config,
       phase: :topics,
       openers: openers || [],
       openers_loading: false,
       error: nil,
       focus_topics: [],
       pending_opener: nil,
       pending_mode: :empty
     )}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result = AI.refresh_openers(config.topics || [], target(config), native(config))
      send(pid, {:openers_loaded, result})
    end)

    {:noreply, assign(socket, openers_loading: true, error: nil)}
  end

  def handle_event("select_opener", %{"opener" => opener}, socket) do
    continue_or_focus(socket, opener, :ai_opens)
  end

  def handle_event("first_message", %{"message" => message}, socket) do
    case String.trim(message) do
      "" -> {:noreply, socket}
      text -> continue_or_focus(socket, text, :user_opens)
    end
  end

  def handle_event("open_topic", %{"topic" => topic}, socket) do
    case String.trim(topic) do
      "" -> {:noreply, socket}
      text -> continue_or_focus(socket, text, :ai_opens_topic)
    end
  end

  def handle_event("select_focus_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode, topic)
  end

  def handle_event("skip_focus_topic", _params, socket) do
    start_conversation(socket, socket.assigns.pending_opener, socket.assigns.pending_mode, nil)
  end

  @impl true
  def handle_info({:openers_loaded, {:ok, openers}}, socket) do
    {:noreply, assign(socket, openers: openers, openers_loading: false)}
  end

  def handle_info({:openers_loaded, {:error, :api_key_not_set}}, socket) do
    {:noreply,
     assign(socket, openers_loading: false, error: gettext("ANTHROPIC_API_KEY not set."))}
  end

  def handle_info({:openers_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       openers_loading: false,
       error: gettext("Could not load conversation openers: %{reason}", reason: inspect(reason))
     )}
  end

  # Either jump straight into the conversation, or ask the student to pick a focus
  # topic first when their pool is non-empty.
  defp continue_or_focus(socket, opener, mode) do
    case FocusTopics.list_active_topics() do
      [] ->
        start_conversation(socket, opener, mode, nil)

      topics ->
        {:noreply,
         assign(socket,
           phase: :focus_topic,
           focus_topics: topics,
           pending_opener: opener,
           pending_mode: mode
         )}
    end
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

  # AI opens about a topic: no seeded message — the continue view asks the partner
  # to start, informed by the conversation's `topic`.
  defp seed_initial_messages(_conversation, _topic, :ai_opens_topic), do: :ok
  defp seed_initial_messages(_conversation, _topic, :empty), do: :ok

  defp target(config), do: config.target_language || "de"
  defp native(config), do: config.native_language || "en"

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

        <%!-- Open-ended option 1: write the first message yourself --%>
        <form phx-submit="first_message" class="border-4 border-ink p-4 block-yellow text-left w-full">
          <div class="font-bold text-base">{gettext("Write the first message")}</div>
          <div class="text-xs opacity-70 mb-2 font-mono">
            {gettext("Your partner will respond to what you write")}
          </div>
          <div class="flex flex-col gap-2">
            <textarea
              id="convo-first-message"
              name="message"
              rows="2"
              phx-hook="AutoExpand"
              data-no-enter-submit
              data-persist-key="convo-first-message"
              placeholder="z.B. Ich habe gestern einen tollen Film gesehen!"
              class="input border-3 border-ink w-full font-mono text-sm min-h-[4.5rem] resize-none overflow-hidden"
            ></textarea>
            <button type="submit" class="brutal-btn self-end px-4 py-2 bg-ink text-paper text-sm">
              {gettext("Go")}
            </button>
          </div>
        </form>

        <%!-- Open-ended option 2: give a topic for the AI to open about --%>
        <form phx-submit="open_topic" class="border-4 border-ink p-4 block-cyan text-left w-full">
          <div class="font-bold text-base">{gettext("Give your partner a topic")}</div>
          <div class="text-xs opacity-70 mb-2 font-mono">
            {gettext("In English or German — your partner opens the conversation about it")}
          </div>
          <div class="flex flex-col gap-2">
            <textarea
              id="convo-open-topic"
              name="topic"
              rows="2"
              phx-hook="AutoExpand"
              data-no-enter-submit
              data-persist-key="convo-open-topic"
              placeholder="z.B. travel plans / Reisepläne"
              class="input border-3 border-ink w-full font-mono text-sm min-h-[4.5rem] resize-none overflow-hidden"
            ></textarea>
            <button type="submit" class="brutal-btn self-end px-4 py-2 bg-ink text-paper text-sm">
              {gettext("Go")}
            </button>
          </div>
        </form>

        <%!-- Or generate openers for inspiration --%>
        <div class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <span class="text-xs font-mono uppercase tracking-widest text-base-content/60">
              {gettext("Need inspiration?")}
            </span>
            <button
              :if={@openers != [] and !@openers_loading}
              phx-click="generate"
              class="brutal-btn px-3 py-1 bg-base-200 text-xs"
            >
              {gettext("Regenerate")}
            </button>
          </div>

          <.retro_loader :if={@openers_loading} message={gettext("Generating openers")} />

          <button
            :if={@openers == [] and !@openers_loading}
            phx-click="generate"
            class="brutal-btn p-4 bg-base-100 hover:bg-base-200 text-left w-full"
          >
            <div class="font-bold text-base">{gettext("Generate 5 openers")}</div>
            <div class="text-xs text-base-content/60 mt-1 font-mono">
              {gettext("Let your partner suggest a way in")}
            </div>
          </button>

          <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>

          <div :if={@openers != [] and !@openers_loading} class="grid gap-3">
            <button
              :for={opener <- @openers}
              phx-click="select_opener"
              phx-value-opener={opener["opener"]}
              class="brutal-btn text-left p-4 bg-base-100 hover:bg-base-200 w-full"
            >
              <div class="font-bold text-base">{opener["opener"]}</div>
              <div class="text-xs text-base-content/60 mt-1 font-mono">{opener["translation"]}</div>
            </button>
          </div>
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
            <.rich_text text={topic.text} class="text-sm normal-case" />
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
