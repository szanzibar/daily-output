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
       push_key_valid: Push.public_key_valid?(),
       vapid_public_key: Application.get_env(:daily_output, :vapid_public_key) || ""
     )}
  end

  @impl true
  def handle_event("validate", %{"config" => params}, socket) do
    changeset =
      socket.assigns.config
      |> Settings.change_config(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"config" => params}, socket) do
    case Settings.update_config(socket.assigns.config, params) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings saved!"))
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

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

  # Explicit "use this timezone" (button or manual entry).
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    if valid_timezone?(tz) do
      persist(socket, %{timezone: tz}, gettext("Timezone updated."))
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown timezone."))}
    end
  end

  def handle_event("save_reminder_time", %{"reminder_time" => value}, socket) do
    case parse_time(value) do
      {:ok, time} -> persist(socket, %{reminder_time: time}, gettext("Reminder time saved."))
      :error -> {:noreply, put_flash(socket, :error, gettext("Invalid time."))}
    end
  end

  def handle_event("enable_reminders", %{"subscription" => subscription}, socket) do
    %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = subscription

    case Push.subscribe(%{endpoint: endpoint, p256dh: p256dh, auth: auth}) do
      {:ok, _} ->
        persist(socket, %{reminders_enabled: true}, gettext("Reminders on. We'll nudge you."))

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not enable reminders."))}
    end
  end

  def handle_event("disable_reminders", %{"endpoint" => endpoint}, socket) do
    Push.delete_by_endpoint(endpoint)
    persist(socket, %{reminders_enabled: false}, gettext("Reminders off."))
  end

  def handle_event("disable_reminders", _params, socket) do
    persist(socket, %{reminders_enabled: false}, gettext("Reminders off."))
  end

  def handle_event("test_notification", _params, socket) do
    payload = %{
      title: gettext("Daily Output"),
      body: gettext("Test notification — push is working."),
      url: "/"
    }

    case Push.send_to_all(payload) do
      0 ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No notification sent. Make sure reminders are enabled on this device.")
         )}

      count ->
        {:noreply,
         put_flash(socket, :info, gettext("Test sent to %{count} device(s).", count: count))}
    end
  end

  defp persist(socket, attrs, flash_msg) do
    case Settings.update_config(socket.assigns.config, attrs) do
      {:ok, config} ->
        socket = assign(socket, config: config, form: to_form(Settings.change_config(config)))
        socket = if flash_msg, do: put_flash(socket, :info, flash_msg), else: socket
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save."))}
    end
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

      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
        <%!-- Timer + Exchanges --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-red"></span> {gettext("Timer & Conversation")}
          </h2>
          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:timer_minutes]}
              type="number"
              label={gettext("Minutes per entry")}
              min="1"
              max="60"
              class="w-24 input font-mono text-lg border-3 border-ink"
            />
            <.input
              field={@form[:min_exchanges]}
              type="number"
              label={gettext("Min. exchanges per conversation")}
              min="1"
              max="50"
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

        <button type="submit" class="brutal-btn w-full py-4 block-blue text-lg">
          {gettext("Save")}
        </button>
      </.form>

      <%!-- Daily reminder --%>
      <div
        :if={@push_configured}
        id="reminders-panel"
        phx-hook="Reminders"
        data-vapid-key={@vapid_public_key}
        data-enabled={to_string(@config.reminders_enabled)}
        data-timezone={@config.timezone || ""}
        class="border-4 border-ink p-5 space-y-4"
      >
        <h2 class="text-lg font-black uppercase flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Daily Reminder")}
        </h2>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Get a nudge at your chosen time if you haven't practiced yet. Works on your phone once the app is installed to your home screen."
          )}
        </p>

        <p
          :if={!@push_key_valid}
          class="text-sm font-mono text-bold-red border-l-4 border-bold-red pl-3"
        >
          {gettext(
            "Your VAPID_PUBLIC_KEY looks invalid (it must be the longer public key). Regenerate with `mix daily_output.gen_vapid` and restart."
          )}
        </p>

        <div class="flex items-center gap-3">
          <span class={[
            "text-xs font-mono px-2 py-1 uppercase",
            if(@config.reminders_enabled, do: "block-green", else: "bg-base-200")
          ]}>
            {if @config.reminders_enabled, do: gettext("On"), else: gettext("Off")}
          </span>
          <button
            :if={!@config.reminders_enabled}
            type="button"
            data-action="enable"
            class="brutal-btn px-4 py-2 block-cyan text-sm"
          >
            {gettext("Enable reminders")}
          </button>
          <button
            :if={@config.reminders_enabled}
            type="button"
            data-action="disable"
            class="brutal-btn px-4 py-2 bg-base-200 text-sm"
          >
            {gettext("Turn off")}
          </button>
          <button
            :if={@config.reminders_enabled}
            type="button"
            data-action="test"
            class="brutal-btn px-4 py-2 block-purple text-sm"
          >
            {gettext("Send test")}
          </button>
        </div>

        <p data-role="error" class="hidden text-sm font-mono text-bold-red"></p>

        <form phx-submit="save_reminder_time" class="flex items-end gap-2">
          <div>
            <label class="block text-xs font-mono uppercase tracking-widest mb-1">
              {gettext("Reminder time")}
            </label>
            <input
              type="time"
              name="reminder_time"
              value={Calendar.strftime(@config.reminder_time, "%H:%M")}
              class="input border-3 border-ink font-mono"
            />
          </div>
          <button type="submit" class="brutal-btn px-4 py-2 block-green text-sm">
            {gettext("Save")}
          </button>
        </form>

        <form phx-submit="set_timezone" class="flex items-end gap-2">
          <div class="flex-1">
            <label class="block text-xs font-mono uppercase tracking-widest mb-1">
              {gettext("Timezone")}
            </label>
            <input
              type="text"
              name="timezone"
              value={@config.timezone}
              placeholder="Europe/Berlin"
              class="input border-3 border-ink font-mono w-full text-sm"
            />
          </div>
          <button
            type="button"
            data-action="detect-tz"
            class="brutal-btn px-3 py-2 bg-base-200 text-sm"
          >
            {gettext("Use current")}
          </button>
          <button type="submit" class="brutal-btn px-4 py-2 block-green text-sm">
            {gettext("Save")}
          </button>
        </form>
      </div>

      <div :if={!@push_configured} class="border-4 border-ink p-5">
        <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Daily Reminder")}
        </h2>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Reminders are unavailable until push keys are set. Run `mix daily_output.gen_vapid` and add the VAPID_* values to your .env."
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
