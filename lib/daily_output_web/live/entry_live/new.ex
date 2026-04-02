defmodule DailyOutputWeb.EntryLive.New do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Journal, Settings, AI, FocusTopics}

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()

    {:ok,
     assign(socket,
       page_title: "Neuer Eintrag",
       config: config,
       phase: :prompts,
       prompts: [],
       prompts_loading: true,
       selected_prompt: nil,
       body: "",
       timer_seconds: (config.timer_minutes || 5) * 60,
       timer_running: false,
       timer_expired: false,
       entry: nil,
       feedback: nil,
       feedback_loading: false,
       error: nil,
       focus_topics: [],
       selected_focus_topic: nil
     )
     |> then(fn socket ->
       if connected?(socket), do: load_prompts(socket), else: socket
     end)}
  end

  defp load_prompts(socket) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result =
        AI.generate_prompts(
          config.topics || [],
          config.target_language || "de",
          config.native_language || "en"
        )

      send(pid, {:prompts_loaded, result})
    end)

    socket
  end

  @impl true
  def handle_info({:prompts_loaded, {:ok, prompts}}, socket) do
    {:noreply, assign(socket, prompts: prompts, prompts_loading: false)}
  end

  def handle_info({:prompts_loaded, {:error, :api_key_not_set}}, socket) do
    {:noreply,
     assign(socket,
       prompts: [],
       prompts_loading: false,
       error:
         "ANTHROPIC_API_KEY nicht gesetzt. In der .env Datei eintragen und Server neu starten."
     )}
  end

  def handle_info({:prompts_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       prompts: [],
       prompts_loading: false,
       error:
         "Prompts konnten nicht generiert werden: #{inspect(reason)}. Du kannst trotzdem Freestyle schreiben!"
     )}
  end

  def handle_info(:tick, socket) do
    remaining = socket.assigns.timer_seconds - 1

    if remaining <= 0 do
      {:noreply, assign(socket, timer_seconds: 0, timer_expired: true, timer_running: false)}
    else
      Process.send_after(self(), :tick, 1000)
      {:noreply, assign(socket, timer_seconds: remaining)}
    end
  end

  def handle_info({:feedback_loaded, {:ok, feedback}, entry}, socket) do
    case Journal.save_feedback(entry, feedback) do
      {:ok, entry} ->
        {:noreply, push_navigate(socket, to: ~p"/entries/#{entry.id}")}

      {:error, _} ->
        {:noreply, assign(socket, feedback: feedback, feedback_loading: false)}
    end
  end

  def handle_info({:feedback_loaded, {:error, reason}, _entry}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: "Feedback konnte nicht geladen werden: #{inspect(reason)}"
     )}
  end

  @impl true
  def handle_event("add_focus_topic", _params, socket) do
    # Feedback redirects to show page, so this is a no-op here
    {:noreply, socket}
  end

  def handle_event("master_focus_topic", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("override_focus_result", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("select_prompt", %{"prompt" => prompt}, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      {:noreply, socket |> assign(selected_prompt: prompt, phase: :writing) |> start_timer()}
    else
      {:noreply,
       assign(socket, selected_prompt: prompt, phase: :focus_topic, focus_topics: topics)}
    end
  end

  def handle_event("freestyle", _params, socket) do
    topics = FocusTopics.list_active_topics()

    if topics == [] do
      {:noreply, socket |> assign(selected_prompt: nil, phase: :writing) |> start_timer()}
    else
      {:noreply, assign(socket, selected_prompt: nil, phase: :focus_topic, focus_topics: topics)}
    end
  end

  def handle_event("select_focus_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    {:noreply, socket |> assign(selected_focus_topic: topic, phase: :writing) |> start_timer()}
  end

  def handle_event("skip_focus_topic", _params, socket) do
    {:noreply, socket |> assign(phase: :writing) |> start_timer()}
  end

  def handle_event("update_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, body: body)}
  end

  def handle_event("complete", _params, socket) do
    body = socket.assigns.body
    config = socket.assigns.config

    if String.trim(body) == "" do
      {:noreply, put_flash(socket, :error, "Schreib zuerst etwas!")}
    else
      focus_topic = socket.assigns.selected_focus_topic

      attrs = %{
        body: body,
        prompt: socket.assigns.selected_prompt,
        language: config.target_language || "de",
        duration: (config.timer_minutes || 5) * 60 - socket.assigns.timer_seconds,
        focus_topic_id: focus_topic && focus_topic.id
      }

      case Journal.create_entry(attrs) do
        {:ok, entry} ->
          entry = Journal.complete_entry(entry) |> elem(1)
          request_feedback(socket, entry, body, config)

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Eintrag konnte nicht gespeichert werden.")}
      end
    end
  end

  defp request_feedback(socket, entry, body, config) do
    focus_topic = socket.assigns.selected_focus_topic

    socket =
      assign(socket,
        entry: entry,
        phase: :feedback,
        feedback_loading: true
      )

    pid = self()

    Task.start(fn ->
      result =
        AI.proofread(body,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || "",
          focus_topic: focus_topic && focus_topic.text
        )

      send(pid, {:feedback_loaded, result, entry})
    end)

    {:noreply, socket}
  end

  defp start_timer(socket) do
    Process.send_after(self(), :tick, 1000)
    assign(socket, timer_running: true)
  end

  defp format_time(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)

    "#{String.pad_leading(Integer.to_string(minutes), 2, "0")}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <%!-- PHASE: Prompt Selection --%>
      <div :if={@phase == :prompts} class="space-y-6">
        <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
          Worüber schreibst du?
        </h1>

        <hr class="brutal-hr" />

        <.retro_loader :if={@prompts_loading} message="Prompts werden geladen" />

        <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>

        <div :if={!@prompts_loading} class="grid gap-3">
          <button
            :for={prompt <- @prompts}
            phx-click="select_prompt"
            phx-value-prompt={prompt["prompt"]}
            class="brutal-btn text-left p-4 bg-base-100 hover:bg-base-200 w-full"
          >
            <div class="font-bold text-base">{prompt["prompt"]}</div>
            <div class="text-xs text-base-content/60 mt-1 font-mono">{prompt["translation"]}</div>
          </button>

          <button
            phx-click="freestyle"
            class="brutal-btn p-4 block-yellow text-left w-full"
          >
            <div class="font-bold text-base">Freestyle</div>
            <div class="text-xs opacity-70 mt-1 font-mono">Schreib worüber du willst</div>
          </button>
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
            <div class="text-xs opacity-70 mt-1 font-mono">Ohne Fokus-Thema schreiben</div>
          </button>
        </div>
      </div>

      <%!-- PHASE: Writing --%>
      <div :if={@phase == :writing}>
        <%!-- Focus topic reminder --%>
        <div :if={@selected_focus_topic} class="border-4 border-ink p-3 block-blue mb-4">
          <span class="text-xs font-mono uppercase tracking-widest">Fokus:</span>
          <span class="text-sm ml-2">{@selected_focus_topic.text}</span>
        </div>

        <.editor id="editor-new" body={@body} prompt={@selected_prompt} error={@error}>
          <:header>
            <div :if={@selected_prompt} class="text-sm font-mono text-base-content/60 truncate mr-4">
              {@selected_prompt}
            </div>
            <div :if={!@selected_prompt} class="text-sm font-mono text-base-content/60">
              Freestyle
            </div>

            <div class={[
              "timer-display text-2xl sm:text-3xl shrink-0",
              @timer_expired && "text-bold-red",
              !@timer_expired && "text-ink"
            ]}>
              {format_time(@timer_seconds)}
            </div>
          </:header>
          <:actions>
            <button
              phx-click="complete"
              class={[
                "brutal-btn px-6 py-3 text-lg",
                if(@timer_expired, do: "block-green", else: "bg-base-200")
              ]}
            >
              Fertig &check;
            </button>
          </:actions>
        </.editor>

        <div :if={@timer_expired} class="block-red px-4 py-2 text-sm font-mono text-center mt-4">
          Zeit ist um! Du kannst weiterschreiben oder den Eintrag abschliessen.
        </div>
      </div>

      <%!-- PHASE: Feedback --%>
      <div :if={@phase == :feedback}>
        <.loading :if={@feedback_loading} title="Feedback" message="Dein Text wird geprüft" />

        <.feedback_view
          :if={@feedback && !@feedback_loading}
          feedback={@feedback}
          error={@error}
        >
          <:actions>
            <.link navigate={~p"/"} class="brutal-btn px-6 py-3 block-yellow no-underline text-lg">
              Zurück
            </.link>
          </:actions>
        </.feedback_view>

        <%!-- Error state: loading finished but no feedback (AI call failed) --%>
        <div :if={@error && !@feedback_loading && !@feedback} class="space-y-6">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            Feedback
          </h1>
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
