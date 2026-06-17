defmodule DailyOutputWeb.EntryLive.New do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Journal, Settings, AI, FocusTopics}

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()
    prompts = AI.cached_prompts(config.topics || [], target(config), native(config))

    {:ok,
     assign(socket,
       page_title: gettext("New Entry"),
       config: config,
       phase: :prompts,
       prompts: prompts || [],
       prompts_loading: false,
       selected_prompt: nil,
       error: nil,
       focus_topics: []
     )}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result = AI.refresh_prompts(config.topics || [], target(config), native(config))
      send(pid, {:prompts_loaded, result})
    end)

    {:noreply, assign(socket, prompts_loading: true, error: nil)}
  end

  def handle_event("select_prompt", %{"prompt" => prompt}, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      start_entry(socket, prompt, nil)
    else
      {:noreply,
       assign(socket, selected_prompt: prompt, phase: :focus_topic, focus_topics: topics)}
    end
  end

  def handle_event("freestyle", _params, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      start_entry(socket, nil, nil)
    else
      {:noreply, assign(socket, selected_prompt: nil, phase: :focus_topic, focus_topics: topics)}
    end
  end

  def handle_event("select_focus_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    start_entry(socket, socket.assigns.selected_prompt, topic)
  end

  def handle_event("skip_focus_topic", _params, socket) do
    start_entry(socket, socket.assigns.selected_prompt, nil)
  end

  @impl true
  def handle_info({:prompts_loaded, {:ok, prompts}}, socket) do
    {:noreply, assign(socket, prompts: prompts, prompts_loading: false)}
  end

  def handle_info({:prompts_loaded, {:error, :api_key_not_set}}, socket) do
    {:noreply,
     assign(socket,
       prompts_loading: false,
       error:
         gettext("ANTHROPIC_API_KEY not set. Add it to the .env file and restart the server.")
     )}
  end

  def handle_info({:prompts_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       prompts_loading: false,
       error:
         gettext("Could not generate prompts: %{reason}. You can still write freestyle!",
           reason: inspect(reason)
         )
     )}
  end

  defp start_entry(socket, prompt, focus_topic) do
    config = socket.assigns.config

    attrs = %{
      body: "",
      prompt: prompt,
      language: config.target_language || "de",
      duration: (config.timer_minutes || 5) * 60,
      focus_topic_id: focus_topic && focus_topic.id
    }

    case Journal.create_entry(attrs) do
      {:ok, entry} ->
        {:noreply, push_navigate(socket, to: ~p"/entries/#{entry.id}/edit")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start entry."))}
    end
  end

  defp target(config), do: config.target_language || "de"
  defp native(config), do: config.native_language || "en"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <%!-- PHASE: Prompt Selection --%>
      <div :if={@phase == :prompts} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          {gettext("What will you write about?")}
        </h1>

        <hr class="brutal-hr" />

        <%!-- Freestyle is the default — write about anything --%>
        <button
          phx-click="freestyle"
          class="brutal-btn p-5 block-yellow text-left w-full"
        >
          <div class="font-bold text-lg">{gettext("Freestyle")}</div>
          <div class="text-sm opacity-70 mt-1 font-mono">
            {gettext("Write about whatever you want — just start.")}
          </div>
        </button>

        <%!-- Or generate prompts for inspiration --%>
        <div class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <span class="text-xs font-mono uppercase tracking-widest text-base-content/60">
              {gettext("Need inspiration?")}
            </span>
            <button
              :if={@prompts != [] and !@prompts_loading}
              phx-click="generate"
              class="brutal-btn px-3 py-1 bg-base-200 text-xs"
            >
              {gettext("Regenerate")}
            </button>
          </div>

          <.retro_loader :if={@prompts_loading} message={gettext("Generating prompts")} />

          <button
            :if={@prompts == [] and !@prompts_loading}
            phx-click="generate"
            class="brutal-btn p-4 bg-base-100 hover:bg-base-200 text-left w-full"
          >
            <div class="font-bold text-base">{gettext("Generate 5 prompts")}</div>
            <div class="text-xs text-base-content/60 mt-1 font-mono">
              {gettext("Get fresh ideas tailored to your topics")}
            </div>
          </button>

          <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>

          <div :if={@prompts != [] and !@prompts_loading} class="grid gap-3">
            <button
              :for={prompt <- @prompts}
              phx-click="select_prompt"
              phx-value-prompt={prompt["prompt"]}
              class="brutal-btn text-left p-4 bg-base-100 hover:bg-base-200 w-full"
            >
              <div class="font-bold text-base">{prompt["prompt"]}</div>
              <div class="text-xs text-base-content/60 mt-1 font-mono">{prompt["translation"]}</div>
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
              {gettext("Write without a focus topic")}
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
