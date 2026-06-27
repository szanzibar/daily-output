defmodule DailyOutputWeb.EntryLive.Edit do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Journal, Settings, AI, FocusTopics, Flashcards}
  alias DailyOutputWeb.Celebration

  @default_timer_minutes 5
  @heuristic_words_per_minute 20

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    entry = Journal.get_entry!(id)
    config = Settings.get_config()
    focus_topic_text = focus_topic_text(entry)
    timer_required_seconds = (config.timer_minutes || @default_timer_minutes) * 60
    timer_enabled = is_nil(entry.feedback) and is_nil(entry.completed_at)

    timer_seconds =
      if timer_enabled do
        timer_seconds_from_body(entry.body || "", timer_required_seconds)
      else
        0
      end

    socket =
      assign(socket,
        page_title:
          gettext("Edit — %{date}", date: Calendar.strftime(entry.inserted_at, "%d.%m.%Y")),
        config: config,
        entry: entry,
        focus_topic_text: focus_topic_text,
        body: entry.body || "",
        phase: :writing,
        feedback: nil,
        feedback_loading: false,
        error: nil,
        timer_enabled: timer_enabled,
        timer_seconds: timer_seconds,
        timer_expired: timer_seconds == 0,
        floor_met: Journal.floor_met?(entry.body || "")
      )

    socket =
      if connected?(socket) and socket.assigns.timer_enabled and socket.assigns.timer_seconds > 0 do
        Process.send_after(self(), :tick, 1000)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("update_body", %{"body" => body}, socket) do
    entry = socket.assigns.entry

    if entry.feedback do
      {:noreply, assign(socket, body: body, floor_met: Journal.floor_met?(body))}
    else
      case Journal.update_entry(entry, %{body: body}) do
        {:ok, updated_entry} ->
          {:noreply,
           assign(socket,
             body: body,
             entry: updated_entry,
             floor_met: Journal.floor_met?(body)
           )}

        {:error, _changeset} ->
          {:noreply, assign(socket, body: body, floor_met: Journal.floor_met?(body))}
      end
    end
  end

  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    DailyOutput.Stats.track(section, seconds)
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    body = socket.assigns.body
    entry = socket.assigns.entry

    if String.trim(body) == "" do
      {:noreply, put_flash(socket, :error, gettext("Write something first!"))}
    else
      # If entry already has feedback, save as a new version (don't overwrite old feedback)
      # If no feedback yet, it's a draft — true edit is fine
      result =
        if entry.feedback do
          Journal.create_entry(version_attrs(entry, body))
        else
          Journal.update_entry(entry, %{body: body})
        end

      case result do
        {:ok, saved_entry} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Saved."))
           |> push_navigate(to: ~p"/entries/#{saved_entry.id}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save."))}
      end
    end
  end

  def handle_event("resubmit", _params, socket) do
    body = socket.assigns.body
    config = socket.assigns.config
    entry = socket.assigns.entry

    remaining = Journal.words_until_floor(body)

    cond do
      String.trim(body) == "" ->
        {:noreply, put_flash(socket, :error, gettext("Write something first!"))}

      socket.assigns.timer_enabled and remaining > 0 ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ngettext(
             "Just %{count} more word and you can finish.",
             "Just %{count} more words and you can finish.",
             remaining
           )
         )}

      true ->
        with {:ok, entry_for_feedback} <-
               (if entry.feedback do
                  Journal.create_entry(version_attrs(entry, body))
                else
                  Journal.update_entry(entry, %{body: body})
                end) do
          request_feedback(socket, entry_for_feedback, body, config)
        else
          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save."))}
        end
    end
  end

  defp timer_seconds_from_body(body, required_seconds) do
    words = body |> String.split(~r/\s+/, trim: true) |> length()
    heuristic_elapsed_seconds = div(words * 60, @heuristic_words_per_minute)

    max(required_seconds - heuristic_elapsed_seconds, 0)
  end

  defp format_time(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)

    "#{String.pad_leading(Integer.to_string(minutes), 2, "0")}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp version_attrs(entry, body) do
    %{
      body: body,
      prompt: entry.prompt,
      language: entry.language,
      duration: entry.duration,
      focus_topic_id: entry.focus_topic_id
    }
  end

  defp request_feedback(socket, entry, body, config) do
    socket =
      assign(socket,
        entry: entry,
        focus_topic_text: focus_topic_text(entry),
        phase: :feedback,
        timer_enabled: false,
        timer_seconds: 0,
        timer_expired: true,
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
          focus_topic: focus_topic_text(entry)
        )

      send(pid, {:feedback_loaded, result, entry})
    end)

    {:noreply, socket}
  end

  defp focus_topic_text(entry) do
    if entry.focus_topic_id do
      FocusTopics.get_topic!(entry.focus_topic_id).text
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.timer_enabled and socket.assigns.timer_seconds > 0 do
      remaining = max(socket.assigns.timer_seconds - 1, 0)

      if remaining > 0 do
        Process.send_after(self(), :tick, 1000)
      end

      {:noreply, assign(socket, timer_seconds: remaining, timer_expired: remaining == 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:feedback_loaded, {:ok, feedback}, entry}, socket) do
    case Journal.save_feedback(entry, feedback) do
      {:ok, entry} ->
        # Best-effort: turn this entry's corrections into flashcards in the background.
        Task.start(fn -> Flashcards.ingest_correction(:entry, entry.id, feedback) end)

        if should_complete_entry?(entry) do
          case Journal.complete_entry(entry) do
            {:ok, completed_entry} ->
              {:noreply, push_navigate(socket, to: completion_path(completed_entry.id))}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Could not complete entry."))}
          end
        else
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Focus topic not used yet. Edit and resubmit to complete the day.")
           )
           |> push_navigate(to: ~p"/entries/#{entry.id}")}
        end

      {:error, _} ->
        {:noreply, assign(socket, feedback: feedback, feedback_loading: false)}
    end
  end

  def handle_info({:feedback_loaded, {:error, :api_key_not_set}, _entry}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error:
         gettext("ANTHROPIC_API_KEY not set. Add it to the .env file and restart the server.")
     )}
  end

  def handle_info({:feedback_loaded, {:error, reason}, _entry}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: gettext("Could not load feedback: %{reason}", reason: inspect(reason))
     )}
  end

  # The completed entry's show page, celebrating if this finished the day or hit a
  # streak milestone (the client renders confetti from the `?celebrate=` token).
  defp completion_path(entry_id) do
    challenge = FocusTopics.daily_challenge_status()
    streak = FocusTopics.streak_info()

    case Celebration.after_completion(challenge.all_done, streak.count) do
      nil -> ~p"/entries/#{entry_id}"
      token -> ~p"/entries/#{entry_id}?#{[celebrate: token]}"
    end
  end

  defp should_complete_entry?(entry) do
    if is_nil(entry.focus_topic_id) do
      true
    else
      case entry.feedback do
        %{"focus_result" => %{} = focus_result} ->
          Map.get(focus_result, "used") == true

        _ ->
          false
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <%!-- Tracks active time spent writing this entry. --%>
      <div id="entry-time-tracker" phx-hook="TimeTracker" data-section="entry" class="hidden"></div>
      <%!-- PHASE: Writing/Editing --%>
      <div :if={@phase == :writing}>
        <div :if={@focus_topic_text} class="border-4 border-ink p-3 block-blue mb-4">
          <span class="text-xs font-mono uppercase tracking-widest">{gettext("Focus:")}</span>
          <.rich_text text={@focus_topic_text} class="text-sm mt-1" />
        </div>

        <.editor id={"editor-#{@entry.id}"} body={@body} prompt={@entry.prompt} error={@error}>
          <:header>
            <div class="flex items-center gap-3">
              <h1 class="text-3xl sm:text-4xl font-black tracking-tighter uppercase">
                {gettext("Edit")}
              </h1>
              <span class="text-sm font-mono text-base-content/60">
                {Calendar.strftime(@entry.inserted_at, "%d.%m.%Y")}
              </span>
            </div>

            <%!-- Gentle target, not a lock: counts down, then cheers when you reach it. --%>
            <div
              :if={@timer_enabled}
              class={[
                "timer-display text-2xl sm:text-3xl shrink-0",
                if(@timer_expired, do: "timer-met", else: "text-base-content/50")
              ]}
              title={gettext("A suggested target — finish whenever you're ready.")}
            >
              {if @timer_expired, do: "✓ " <> gettext("Target!"), else: format_time(@timer_seconds)}
            </div>
          </:header>
          <:actions>
            <.link
              navigate={~p"/entries/#{@entry.id}"}
              class="brutal-btn px-4 py-2 block-dark text-sm no-underline"
            >
              {gettext("Cancel")}
            </.link>
            <button phx-click="save" class="brutal-btn px-4 py-2 block-cyan text-sm">
              {if @entry.feedback, do: gettext("Save"), else: gettext("Save Draft")}
            </button>
            <button
              phx-click="resubmit"
              disabled={@timer_enabled and !@floor_met}
              class={[
                "brutal-btn px-6 py-3 text-lg",
                if(@timer_enabled and !@floor_met,
                  do: "bg-base-200 opacity-60 cursor-not-allowed",
                  else: "block-green"
                )
              ]}
            >
              <%= cond do %>
                <% @entry.feedback -> %>
                  {gettext("New Feedback")} &check;
                <% true -> %>
                  {gettext("Done")} &check;
              <% end %>
            </button>
          </:actions>
        </.editor>
      </div>

      <%!-- PHASE: Feedback --%>
      <div :if={@phase == :feedback}>
        <.loading
          :if={@feedback_loading}
          title={gettext("Feedback")}
          message={gettext("Your text is being reviewed")}
        />

        <.feedback_view
          :if={@feedback && !@feedback_loading}
          feedback={@feedback}
          error={@error}
        >
          <:actions>
            <.link
              navigate={~p"/entries/#{@entry.id}"}
              class="brutal-btn px-6 py-3 block-yellow no-underline text-lg"
            >
              {gettext("Back to entry")}
            </.link>
          </:actions>
        </.feedback_view>

        <div :if={@error && !@feedback_loading && !@feedback} class="space-y-6">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            {gettext("Feedback")}
          </h1>
          <hr class="brutal-hr" />
          <div class="border-4 border-ink p-5 block-red">
            <p class="font-mono text-sm">{@error}</p>
          </div>
          <.link
            navigate={~p"/entries/#{@entry.id}"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            {gettext("Back to entry")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
