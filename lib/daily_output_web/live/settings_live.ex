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

        <%!-- About you --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-yellow"></span> {gettext("About you")}
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext(
              "What you like to talk about, your goals, and anything else the AI should know. Today's topics and prompts come from this."
            )}
          </p>
          <.input
            field={@form[:about_you]}
            type="textarea"
            placeholder={
              gettext(
                "e.g. I sing in a choir, I'm moving to Zurich, and I struggle with verb tenses."
              )
            }
            rows="4"
            phx-hook="AutoExpand"
            data-persist-key="settings-about-you"
            data-no-enter-submit
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

        <%!-- Theme --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-dark"></span> {gettext("Appearance")}
          </h2>
          <.input
            field={@form[:theme]}
            type="select"
            label={gettext("Color theme")}
            options={theme_options()}
            class="w-full select border-3 border-ink font-mono"
            phx-hook=".ThemeSelect"
          />
          <%!-- <html data-theme> lives in the root layout, outside the LiveView DOM, so a
               saved theme wouldn't show until a full reload. Flip it on the client on change.
               Mapping mirrors DailyOutputWeb.Locale (light/dark → brutalist-*, auto → none). --%>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeSelect">
            export default {
              mounted() {
                this.el.addEventListener("change", () => {
                  const themes = {light: "brutalist-light", dark: "brutalist-dark"}
                  const theme = themes[this.el.value]
                  if (theme) {
                    document.documentElement.setAttribute("data-theme", theme)
                  } else {
                    document.documentElement.removeAttribute("data-theme")
                  }
                })
              }
            }
          </script>
        </div>

        <%!-- AI model & provider --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-pink"></span> {gettext("AI Model")}
          </h2>
          <div id="ai-models" class="grid sm:grid-cols-2 gap-3 mb-2 text-sm">
            <div :for={{name, score, price} <- ai_models()} class="border-3 border-ink p-3">
              <p class="font-black">{name}</p>
              <p class="font-mono text-xs text-base-content/70">
                {gettext("Score %{score}", score: score)} · {price}
              </p>
            </div>
          </div>
          <p class="text-xs font-mono text-base-content/50 mb-4">
            {gettext("Scores from benchlm.ai, Oct 2026. Prices per million input / output tokens.")}
          </p>
          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:ai_model]}
              type="select"
              label={gettext("Model")}
              options={ai_model_options()}
              class="w-full select border-3 border-ink font-mono"
            />
            <.input
              field={@form[:ai_provider]}
              type="select"
              label={gettext("Provider")}
              options={ai_provider_options()}
              class="w-full select border-3 border-ink font-mono"
            />
          </div>

          <%!-- Live key status: which env var must be set follows the two choices above. --%>
          <div class="mt-4 space-y-2">
            <div class="flex flex-wrap items-center gap-2">
              <span class={[
                "text-xs font-mono px-2 py-1 uppercase",
                if(api_key_ok?(@config), do: "block-green", else: "block-red")
              ]}>
                {if(api_key_ok?(@config), do: gettext("Key set"), else: gettext("Key missing"))}
              </span>
              <span class="text-sm text-base-content/60">{required_env_var(@config)}</span>
            </div>
            <p :if={!api_key_ok?(@config)} class="text-xs text-base-content/60 font-mono">
              {gettext("Set %{var} in your .env file.", var: required_env_var(@config))}
            </p>
          </div>
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
    </div>
    """
  end

  defp language_options do
    ["de", "en", "fr", "es", "it", "pt", "ja"]
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

  defp theme_options do
    [
      {gettext("Follow OS"), "auto"},
      {gettext("Light"), "light"},
      {gettext("Dark"), "dark"}
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
        "ja" -> "日本語"
        _ -> String.upcase(code)
      end

    profile = LanguageProfile.resolve(code)

    if profile.settings_context do
      "#{base_name} (#{profile.settings_context})"
    else
      base_name
    end
  end

  defp ai_models do
    [{"Claude Sonnet 5.5", "83.4", "$2 / $10"}, {"GPT-5.6 Luna", "66.2", "$0.20 / $1.20"}]
  end

  defp ai_model_options do
    [{"Claude Sonnet 5.5", "sonnet-5.5"}, {"GPT-5.6 Luna", "gpt-5.6-luna"}]
  end

  defp ai_provider_options do
    [{gettext("Native API"), "direct"}, {"OpenRouter", "openrouter"}]
  end

  # Which provider the current choice routes to; AI.spec_for/2 is the single source of truth,
  # so the key status can't drift from what a call actually uses.
  defp required_provider(config) do
    DailyOutput.AI.spec_for(config.ai_provider, config.ai_model)
    |> String.split(":", parts: 2)
    |> hd()
    |> String.to_existing_atom()
  end

  defp required_env_var(config), do: DailyOutput.AI.api_key_var(required_provider(config))

  defp api_key_ok?(config), do: DailyOutput.AI.api_key_set?(required_provider(config))
end
