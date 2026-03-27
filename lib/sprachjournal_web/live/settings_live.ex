defmodule SprachjournalWeb.SettingsLive do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok, config} = Settings.ensure_config()
    changeset = Settings.change_config(config)

    {:ok,
     assign(socket,
       page_title: "Einstellungen",
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
         |> put_flash(:info, "Einstellungen gespeichert!")
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

  def handle_event("update_topic_input", %{"topic" => value}, socket) do
    {:noreply, assign(socket, topic_input: value)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        Einstellungen
      </h1>

      <hr class="brutal-hr" />

      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
        <%!-- Timer --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-red"></span> Timer
          </h2>
          <.input
            field={@form[:timer_minutes]}
            type="number"
            label="Minuten pro Eintrag"
            min="1"
            max="60"
            class="w-24 input font-mono text-lg border-3 border-ink"
          />
        </div>

        <%!-- Languages --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-blue"></span> Sprachen
          </h2>
          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:target_language]}
              type="select"
              label="Zielsprache"
              options={language_options()}
              class="w-full select border-3 border-ink font-mono"
            />
            <.input
              field={@form[:native_language]}
              type="select"
              label="Muttersprache"
              options={language_options()}
              class="w-full select border-3 border-ink font-mono"
            />
          </div>
        </div>

        <%!-- Language Level --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-green"></span> Niveau
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            Your CEFR level. Feedback will be calibrated — only flagging errors you should know at this level.
          </p>
          <.input
            field={@form[:language_level]}
            type="select"
            label="Sprachniveau"
            options={level_options()}
            class="w-full select border-3 border-ink font-mono"
          />
        </div>

        <%!-- Topics --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-yellow"></span> Themen
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            Topics for AI-generated writing prompts. What do you want to practice talking about?
          </p>

          <div class="flex gap-2 mb-3">
            <form phx-submit="add_topic" class="flex gap-2 flex-1">
              <input
                type="text"
                name="topic"
                value={@topic_input}
                phx-change="update_topic_input"
                placeholder="z.B. Arbeit, Einkaufen, Nachbarn..."
                class="input border-3 border-ink flex-1 font-mono text-sm"
              />
              <button type="submit" class="brutal-btn px-4 py-2 block-green text-sm">
                +
              </button>
            </form>
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
            <span class="inline-block w-3 h-3 block-orange"></span> Prompt-Kontext
          </h2>
          <p class="text-sm text-base-content/60 mb-3">
            Extra context injected into the AI prompt. Tell it about your specific goals, weaknesses, or preferences.
          </p>
          <.input
            field={@form[:prompt_context]}
            type="textarea"
            label="Additional instructions for the AI"
            placeholder="e.g. I struggle with Dativ/Akkusativ. I want to practice Konjunktiv II. Focus on formal register."
            rows="4"
            class="w-full textarea border-3 border-ink font-mono text-sm"
          />
        </div>

        <button type="submit" class="brutal-btn w-full py-4 block-blue text-lg">
          Speichern
        </button>
      </.form>

      <%!-- API Key status --%>
      <div class="border-4 border-ink p-5">
        <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-pink"></span> API
        </h2>
        <div class="flex items-center gap-2">
          <span :if={api_key_set?()} class="text-xs font-mono px-2 py-1 block-green uppercase">
            Konfiguriert
          </span>
          <span :if={!api_key_set?()} class="text-xs font-mono px-2 py-1 block-red uppercase">
            Fehlt
          </span>
          <span class="text-sm text-base-content/60">
            ANTHROPIC_API_KEY
          </span>
        </div>
        <p :if={!api_key_set?()} class="text-xs text-base-content/60 mt-2 font-mono">
          Set the ANTHROPIC_API_KEY environment variable to enable AI features.
        </p>
      </div>
    </div>
    """
  end

  defp language_options do
    [
      {"Deutsch", "de"},
      {"English", "en"},
      {"Français", "fr"},
      {"Español", "es"},
      {"Italiano", "it"},
      {"Português", "pt"}
    ]
  end

  defp level_options do
    [
      {"A1 — Anfänger", "A1"},
      {"A2 — Grundlegende Kenntnisse", "A2"},
      {"B1 — Fortgeschrittene Sprachverwendung", "B1"},
      {"B2 — Selbständige Sprachverwendung", "B2"},
      {"C1 — Fachkundige Sprachkenntnisse", "C1"},
      {"C2 — Annähernd muttersprachlich", "C2"}
    ]
  end

  defp api_key_set? do
    System.get_env("ANTHROPIC_API_KEY") not in [nil, ""]
  end
end
