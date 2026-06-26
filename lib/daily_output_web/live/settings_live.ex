defmodule DailyOutputWeb.SettingsLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Push, Settings}
  alias DailyOutput.AI.LanguageProfile

  @impl true
  def mount(_params, _session, socket) do
    {:ok, config} = Settings.ensure_config()
    changeset = Settings.change_config(config)

    {:ok,
     assign(socket,
       page_title: gettext("Settings"),
       config: config,
       form: to_form(changeset),
       topic_input: "",
       push_configured: Push.configured?(),
       vapid_public_key: Push.vapid_public_key(),
       # Per-device push state. :unknown until the browser reports its
       # subscription via the "device_status" event on hook mount.
       device_status: :unknown,
       device_endpoint: nil,
       device_count: Push.count()
     )}
  end

  # Auto-save: every change to the main settings form is persisted immediately.
  # Invalid input is rejected and shown inline; the last good value stays saved.
  @impl true
  def handle_event("save_form", %{"config" => params}, socket) do
    case Settings.update_config(socket.assigns.config, params) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config, form: to_form(Settings.change_config(config)))
         |> toast(gettext("Saved"))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("save_form", _params, socket), do: {:noreply, socket}

  def handle_event("add_topic", %{"topic" => topic}, socket) do
    topic = String.trim(topic)

    if topic != "" and topic not in socket.assigns.config.topics do
      new_topics = socket.assigns.config.topics ++ [topic]

      case Settings.update_config(socket.assigns.config, %{topics: new_topics}) do
        {:ok, config} ->
          changeset = Settings.change_config(config)
          {:noreply, assign(socket, config: config, form: to_form(changeset), topic_input: "")}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, assign(socket, topic_input: "")}
    end
  end

  def handle_event("remove_topic", %{"topic" => topic}, socket) do
    new_topics = List.delete(socket.assigns.config.topics, topic)

    case Settings.update_config(socket.assigns.config, %{topics: new_topics}) do
      {:ok, config} ->
        changeset = Settings.change_config(config)
        {:noreply, assign(socket, config: config, form: to_form(changeset))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("update_topic_input", %{"key" => "Enter", "value" => value}, socket) do
    # Enter pressed — add the topic
    topic = String.trim(value)

    if topic != "" and topic not in socket.assigns.config.topics do
      new_topics = socket.assigns.config.topics ++ [topic]

      case Settings.update_config(socket.assigns.config, %{topics: new_topics}) do
        {:ok, config} ->
          changeset = Settings.change_config(config)
          {:noreply, assign(socket, config: config, form: to_form(changeset), topic_input: "")}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, assign(socket, topic_input: "")}
    end
  end

  def handle_event("update_topic_input", params, socket) do
    value = params["topic_input"] || params["value"] || ""
    {:noreply, assign(socket, topic_input: value)}
  end

  # ── Reminders & timezone ────────────────────────────────

  # Auto-detect the browser timezone on first visit if none is set yet.
  def handle_event("detect_timezone", %{"timezone" => tz}, socket) do
    if is_nil(socket.assigns.config.timezone) and valid_timezone?(tz) do
      persist(socket, %{timezone: tz}, nil)
    else
      {:noreply, socket}
    end
  end

  # Auto-saved on blur / detect. Empty clears back to the default timezone.
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    cond do
      String.trim(tz) == "" -> persist(socket, %{timezone: nil}, gettext("Saved"))
      valid_timezone?(tz) -> persist(socket, %{timezone: tz}, gettext("Saved"))
      true -> {:noreply, toast(socket, gettext("Unknown timezone."), :error)}
    end
  end

  def handle_event("save_reminder_time", %{"reminder_time" => value}, socket) do
    case parse_time(value) do
      {:ok, time} -> persist(socket, %{reminder_time: time}, gettext("Saved"))
      :error -> {:noreply, toast(socket, gettext("Invalid time."), :error)}
    end
  end

  # The browser reports its current push subscription on hook mount (endpoint, or
  # nil if it isn't subscribed). A device is "on" iff that endpoint is in our DB.
  def handle_event("device_status", %{"endpoint" => endpoint}, socket) do
    status = if Push.subscribed?(endpoint), do: :on, else: :off

    {:noreply,
     assign(socket, device_status: status, device_endpoint: endpoint, device_count: Push.count())}
  end

  def handle_event("enable_reminders", %{"subscription" => subscription}, socket) do
    %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = subscription

    case Push.subscribe(%{endpoint: endpoint, p256dh: p256dh, auth: auth}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(device_status: :on, device_endpoint: endpoint, device_count: Push.count())
         |> toast(gettext("Reminders on for this device."))}

      {:error, _} ->
        {:noreply, toast(socket, gettext("Could not enable reminders."), :error)}
    end
  end

  def handle_event("disable_reminders", params, socket) do
    endpoint = params["endpoint"] || socket.assigns.device_endpoint
    if endpoint, do: Push.delete_by_endpoint(endpoint)

    {:noreply,
     socket
     |> assign(device_status: :off, device_count: Push.count())
     |> toast(gettext("Reminders off for this device."))}
  end

  def handle_event("test_notification", params, socket) do
    endpoint = params["endpoint"] || socket.assigns.device_endpoint

    payload = %{
      title: gettext("Daily Output"),
      body: gettext("Test notification — push is working."),
      url: "/"
    }

    case endpoint && Push.send_to_endpoint(endpoint, payload) do
      1 ->
        {:noreply, toast(socket, gettext("Test sent to this device."))}

      _ ->
        {:noreply,
         toast(
           socket,
           gettext("No notification sent. Make sure reminders are enabled on this device."),
           :error
         )}
    end
  end

  defp persist(socket, attrs, message) do
    case Settings.update_config(socket.assigns.config, attrs) do
      {:ok, config} ->
        socket = assign(socket, config: config, form: to_form(Settings.change_config(config)))
        {:noreply, if(message, do: toast(socket, message), else: socket)}

      {:error, _changeset} ->
        {:noreply, toast(socket, gettext("Could not save."), :error)}
    end
  end

  # Client-rendered toast (see app.js). Fires on every event, so rapid changes each get
  # their own visible toast — unlike Phoenix flash, which dedupes identical messages.
  defp toast(socket, message, kind \\ :info) do
    push_event(socket, "toast", %{message: message, kind: to_string(kind)})
  end

  defp parse_time(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp valid_timezone?(tz) when is_binary(tz) and tz != "", do: match?({:ok, _}, DateTime.now(tz))
  defp valid_timezone?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        {gettext("Settings")}
      </h1>

      <hr class="brutal-hr" />

      <.form
        for={@form}
        id="settings-form"
        phx-change="save_form"
        phx-debounce="500"
        class="space-y-6"
      >
        <%!-- Timer + Exchanges --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-red"></span> {gettext("Timer & Conversation")}
          </h2>
          <%!-- Labels share the top row, inputs share the bottom row, so a label that
               wraps to two lines never knocks its input out of line with the other. --%>
          <div class="grid grid-cols-2 gap-x-4 gap-y-1">
            <label for={@form[:timer_minutes].id} class="label">
              {gettext("Minutes per entry")}
            </label>
            <label for={@form[:min_exchanges].id} class="label">
              {gettext("Min. exchanges per conversation")}
            </label>
            <.input
              field={@form[:timer_minutes]}
              type="number"
              min="1"
              max="60"
              class="w-24 input font-mono text-lg border-3 border-ink"
            />
            <.input
              field={@form[:min_exchanges]}
              type="number"
              min="1"
              max="50"
              class="w-24 input font-mono text-lg border-3 border-ink"
            />
          </div>
        </div>

        <%!-- Flashcards --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Flashcards")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext(
              "How many cards make a full flashcard day. New cards are added automatically to fill this target."
            )}
          </p>
          <div class="grid grid-cols-2 gap-x-4 gap-y-1">
            <label for={@form[:flashcards_per_day].id} class="label">
              {gettext("Cards per day")}
            </label>
            <span></span>
            <.input
              field={@form[:flashcards_per_day]}
              type="number"
              min="1"
              max="100"
              class="w-24 input font-mono text-lg border-3 border-ink"
            />
          </div>
        </div>

        <%!-- Languages --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-blue"></span> {gettext("Languages")}
          </h2>
          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:target_language]}
              type="select"
              label={gettext("Target language")}
              options={language_options()}
              class="w-full select border-3 border-ink font-mono"
            />
            <.input
              field={@form[:native_language]}
              type="select"
              label={gettext("Native language")}
              options={language_options()}
              class="w-full select border-3 border-ink font-mono"
            />
          </div>
        </div>

        <%!-- Language Level --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-green"></span> {gettext("Level")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext(
              "Your CEFR level. Feedback is calibrated — only errors you should know at this level. From B2, feedback is in the target language."
            )}
          </p>
          <.input
            field={@form[:language_level]}
            type="select"
            label={gettext("Language level")}
            options={level_options()}
            class="w-full select border-3 border-ink font-mono"
          />
        </div>

        <%!-- Topics --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-yellow"></span> {gettext("Topics")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext("Topics for AI-generated writing prompts. What would you like to write about?")}
          </p>

          <div class="flex gap-2 mb-3">
            <input
              type="text"
              name="topic_input"
              value={@topic_input}
              phx-keyup="update_topic_input"
              phx-key="Enter"
              placeholder={gettext("e.g. Work, Shopping, Neighbors...")}
              class="input border-3 border-ink flex-1 font-mono text-sm"
              phx-change="update_topic_input"
            />
            <button
              type="button"
              phx-click="add_topic"
              phx-value-topic={@topic_input}
              class="brutal-btn px-4 py-2 block-green text-sm"
            >
              +
            </button>
          </div>

          <div :if={@config.topics != []} class="flex flex-wrap gap-2">
            <span
              :for={topic <- @config.topics}
              class="inline-flex items-center gap-1 px-3 py-1 border-3 border-ink bg-base-200 text-sm font-mono"
            >
              {topic}
              <button
                type="button"
                phx-click="remove_topic"
                phx-value-topic={topic}
                class="ml-1 text-bold-red hover:text-ink cursor-pointer font-bold"
              >
                &times;
              </button>
            </span>
          </div>
        </div>

        <%!-- Prompt Context --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-orange"></span> {gettext("Prompt Context")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext(
              "Additional context for the AI. Tell it about your goals, weaknesses, or preferences."
            )}
          </p>
          <.input
            field={@form[:prompt_context]}
            type="textarea"
            label={gettext("Additional instructions for the AI")}
            placeholder="z.B. Ich habe Schwierigkeiten mit Dativ/Akkusativ. Ich möchte Konjunktiv II üben."
            rows="4"
            class="w-full textarea border-3 border-ink font-mono text-sm"
          />
        </div>

        <%!-- UI Language --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-purple"></span> {gettext("UI Language")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext("Language for the app interface. Auto uses the target language at B1+ level.")}
          </p>
          <.input
            field={@form[:ui_language]}
            type="select"
            label={gettext("Interface language")}
            options={ui_language_options()}
            class="w-full select border-3 border-ink font-mono"
          />
        </div>
      </.form>

      <%!-- Daily reminder --%>
      <div
        :if={@push_configured}
        id="reminders-panel"
        phx-hook="Reminders"
        data-vapid-key={@vapid_public_key}
        data-timezone={@config.timezone || ""}
        class="border-4 border-ink p-5 space-y-4"
      >
        <h2 class="text-lg font-black uppercase flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Daily Reminder")}
        </h2>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Get a nudge at your chosen time if you haven't practiced yet. Reminders are managed per device — turn them on for each browser or phone where you want them. Works on your phone once the app is installed to your home screen."
          )}
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <span class={[
            "text-xs font-mono px-2 py-1 uppercase",
            if(@device_status == :on, do: "block-green", else: "bg-base-200")
          ]}>
            {case @device_status do
              :on -> gettext("On — this device")
              :off -> gettext("Off")
              :unknown -> gettext("Checking…")
            end}
          </span>
          <button
            :if={@device_status == :off}
            type="button"
            data-action="enable"
            class="brutal-btn px-4 py-2 block-cyan text-sm"
          >
            {gettext("Enable on this device")}
          </button>
          <button
            :if={@device_status == :on}
            type="button"
            data-action="disable"
            class="brutal-btn px-4 py-2 bg-base-200 text-sm"
          >
            {gettext("Turn off here")}
          </button>
          <button
            :if={@device_status == :on}
            type="button"
            data-action="test"
            class="brutal-btn px-4 py-2 block-purple text-sm"
          >
            {gettext("Send test")}
          </button>
        </div>

        <p :if={@device_count > 0} class="text-xs font-mono text-base-content/60">
          {ngettext(
            "Reminders active on %{count} device.",
            "Reminders active on %{count} devices.",
            @device_count
          )}
        </p>

        <p data-role="error" class="hidden text-sm font-mono text-bold-red"></p>

        <form phx-change="save_reminder_time" class="space-y-1">
          <label class="block text-xs font-mono uppercase tracking-widest">
            {gettext("Reminder time")}
          </label>
          <input
            type="time"
            name="reminder_time"
            value={Calendar.strftime(@config.reminder_time, "%H:%M")}
            class="input border-3 border-ink font-mono"
          />
        </form>

        <form phx-change="set_timezone" class="space-y-1">
          <label class="block text-xs font-mono uppercase tracking-widest">
            {gettext("Timezone")}
          </label>
          <div class="flex items-stretch gap-2">
            <input
              id="timezone-input"
              type="text"
              name="timezone"
              value={@config.timezone}
              placeholder="Europe/Berlin"
              phx-debounce="blur"
              class="input border-3 border-ink font-mono w-full text-sm min-w-0 flex-1"
            />
            <button
              type="button"
              data-action="detect-tz"
              class="brutal-btn px-3 bg-base-200 shrink-0 inline-flex items-center justify-center"
              aria-label={gettext("Use current timezone")}
              title={gettext("Use current timezone")}
            >
              <.icon name="hero-map-pin" class="w-5 h-5" />
            </button>
          </div>
        </form>
      </div>

      <div :if={!@push_configured} class="border-4 border-ink p-5">
        <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Daily Reminder")}
        </h2>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Reminders are temporarily unavailable — push keys could not be loaded. Check the server logs and restart."
          )}
        </p>
      </div>

      <%!-- API Key status --%>
      <div class="border-4 border-ink p-5">
        <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-pink"></span> API
        </h2>
        <div class="flex items-center gap-2">
          <span :if={api_key_set?()} class="text-xs font-mono px-2 py-1 block-green uppercase">
            {gettext("Configured")}
          </span>
          <span :if={!api_key_set?()} class="text-xs font-mono px-2 py-1 block-red uppercase">
            {gettext("Missing")}
          </span>
          <span class="text-sm text-base-content/60">
            ANTHROPIC_API_KEY
          </span>
        </div>
        <p :if={!api_key_set?()} class="text-xs text-base-content/60 mt-2 font-mono">
          {gettext("Set the ANTHROPIC_API_KEY environment variable in the .env file.")}
        </p>
      </div>
    </div>
    """
  end

  defp language_options do
    ["de", "en", "fr", "es", "it", "pt"]
    |> Enum.map(fn code -> {language_option_label(code), code} end)
  end

  defp level_options do
    [
      {"A1 — " <> gettext("Beginner"), "A1"},
      {"A2 — " <> gettext("Elementary"), "A2"},
      {"B1 — " <> gettext("Intermediate"), "B1"},
      {"B2 — " <> gettext("Upper Intermediate"), "B2"},
      {"C1 — " <> gettext("Advanced"), "C1"},
      {"C2 — " <> gettext("Near Native"), "C2"}
    ]
  end

  defp ui_language_options do
    [
      {gettext("Auto (based on level)"), "auto"},
      {language_option_label("en"), "en"},
      {language_option_label("de"), "de"}
    ]
  end

  defp language_option_label(code) do
    base_name =
      case code do
        "de" -> "Deutsch"
        "en" -> "English"
        "fr" -> "Français"
        "es" -> "Español"
        "it" -> "Italiano"
        "pt" -> "Português"
        _ -> String.upcase(code)
      end

    profile = LanguageProfile.resolve(code)

    if profile.settings_context do
      "#{base_name} (#{profile.settings_context})"
    else
      base_name
    end
  end

  defp api_key_set? do
    Application.get_env(:daily_output, :anthropic_api_key) not in [nil, ""]
  end
end
