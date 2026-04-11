defmodule DailyOutputWeb.SettingsLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Settings
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
       topic_input: ""
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
