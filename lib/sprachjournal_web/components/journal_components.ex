defmodule SprachjournalWeb.JournalComponents do
  @moduledoc """
  Shared components for journal entry writing and feedback display.
  """
  use Phoenix.Component

  # ── Editor ──────────────────────────────────────────────

  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :prompt, :string, default: nil
  attr :error, :string, default: nil
  slot :header, required: true
  slot :actions, required: true

  def editor(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        {render_slot(@header)}
      </div>

      <div
        :if={@prompt}
        class="text-sm font-mono text-base-content/60 border-l-4 border-ink pl-3 mb-4"
      >
        Prompt: {@prompt}
      </div>

      <textarea
        id={@id}
        phx-hook="AutoSave"
        phx-update="ignore"
        class="journal-editor"
        placeholder="Schreib los..."
        autofocus
      >{@body}</textarea>

      <div class="flex flex-wrap items-center justify-between gap-2 mt-4">
        <span class="text-xs font-mono text-base-content/60">
          {word_count(@body)} Wörter
        </span>
        <div class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>

      <p :if={@error} class="text-sm font-mono text-bold-red mt-2">{@error}</p>
    </div>
    """
  end

  # ── Inline Feedback (college professor style) ───────────

  attr :feedback, :map, required: true
  attr :error, :string, default: nil
  attr :source_type, :string, default: nil
  attr :source_id, :integer, default: nil
  attr :focus_pool_texts, :any, default: %MapSet{}
  attr :focus_mastered, :boolean, default: false
  slot :actions, required: true

  def feedback_view(assigns) do
    annotations_json =
      (assigns.feedback["annotations"] || [])
      |> Jason.encode!()

    assigns = assign(assigns, :annotations_json, annotations_json)

    ~H"""
    <div class="space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        Feedback
      </h1>

      <hr class="brutal-hr" />

      <%!-- Encouragement --%>
      <div :if={@feedback["encouragement"]} class="border-4 border-ink p-5 block-yellow">
        <p class="font-bold text-base">{@feedback["encouragement"]}</p>
      </div>

      <%!-- Annotated text — rendered by JS hook for precise measurement --%>
      <div class="border-4 border-ink p-4">
        <h2 class="text-lg font-black uppercase mb-4 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-red"></span> Korrekturen
        </h2>

        <div
          id="annotated-text"
          phx-hook="AnnotatedText"
          class="annotated-text"
          data-annotated-text={@feedback["annotated_text"] || ""}
          data-annotations={@annotations_json}
        >
        </div>
      </div>

      <%!-- Focus Result --%>
      <.focus_result_box
        :if={@feedback["focus_result"]}
        result={@feedback["focus_result"]}
        focus_mastered={@focus_mastered}
      />

      <%!-- Commentary / Tipps with "+" to add to focus pool --%>
      <div :if={@feedback["commentary"] != []} class="border-4 border-ink p-5">
        <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-blue"></span> Tipps
        </h2>
        <div
          :for={item <- @feedback["commentary"] || []}
          class="mb-3 last:mb-0 flex items-start gap-2"
        >
          <div class="flex-1">
            <span class="text-xs font-mono uppercase px-2 py-0.5 border-2 border-ink mr-2">
              {item["type"]}
            </span>
            <span class="text-sm">{item["text"]}</span>
          </div>
          <%= if @source_type do %>
            <%= if item["text"] in @focus_pool_texts do %>
              <span class="brutal-btn px-2 py-0.5 block-green text-xs shrink-0">
                ✓
              </span>
            <% else %>
              <button
                phx-click="add_focus_topic"
                phx-value-text={item["text"]}
                phx-value-source_type={@source_type}
                phx-value-source_id={@source_id}
                class="brutal-btn px-2 py-0.5 block-blue text-xs shrink-0 phx-click-loading:opacity-50 phx-click-loading:animate-pulse"
              >
                +
              </button>
            <% end %>
          <% end %>
        </div>
      </div>

      <div class="flex gap-3">
        {render_slot(@actions)}
      </div>

      <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>
    </div>
    """
  end

  # ── Focus Result ────────────────────────────────────────

  attr :result, :map, required: true
  attr :focus_mastered, :boolean, default: false

  def focus_result_box(assigns) do
    ~H"""
    <div class={[
      "border-4 border-ink p-5",
      cond do
        @result["used"] && @result["correct"] -> "block-green"
        @result["used"] -> "block-orange"
        true -> "block-red"
      end
    ]}>
      <h2 class="text-lg font-black uppercase mb-2 flex items-center gap-2">
        Fokus-Ergebnis
      </h2>
      <p class="text-sm font-bold mb-2">
        <%= cond do %>
          <% @result["used"] && @result["correct"] -> %>
            Richtig verwendet!
          <% @result["used"] -> %>
            Versucht — weiter üben!
          <% true -> %>
            Nicht verwendet.
        <% end %>
      </p>
      <p :if={@result["comment"]} class="text-sm">{@result["comment"]}</p>
      <div class="flex flex-wrap gap-2 mt-3">
        <%= if @result["used"] && @result["correct"] do %>
          <%= if @focus_mastered do %>
            <span class="brutal-btn px-4 py-1.5 block-green text-xs">
              ✓ Gemeistert
            </span>
          <% else %>
            <button
              phx-click="master_focus_topic"
              class="brutal-btn px-4 py-1.5 bg-ink text-paper text-xs"
            >
              Gemeistert — aus Pool entfernen
            </button>
          <% end %>
        <% end %>
        <button
          :if={!@result["used"]}
          phx-click="override_focus_result"
          class="brutal-btn px-4 py-1.5 block-dark text-xs"
        >
          Ich habe es doch verwendet
        </button>
      </div>
    </div>
    """
  end

  # ── Loading ─────────────────────────────────────────────

  attr :title, :string, default: nil
  attr :message, :string, default: "Laden..."

  def loading(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 :if={@title} class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        {@title}
      </h1>
      <hr :if={@title} class="brutal-hr" />
      <.retro_loader message={@message} />
    </div>
    """
  end

  attr :message, :string, default: "Laden..."

  def retro_loader(assigns) do
    ~H"""
    <div class="py-8 sm:py-12">
      <div class="loading-retro">
        <div class="loading-blocks">
          <span class="loading-block block-red"></span>
          <span class="loading-block block-blue"></span>
          <span class="loading-block block-yellow"></span>
          <span class="loading-block block-green"></span>
          <span class="loading-block block-pink"></span>
        </div>
        <div class="loading-typewriter">
          <span class="loading-cursor">_</span>
        </div>
        <p class="text-sm font-mono text-base-content/60 mt-4 text-center tracking-widest uppercase">
          {@message}
        </p>
        <div class="loading-bar">
          <div class="loading-bar-fill"></div>
        </div>
      </div>
    </div>
    """
  end

  defp word_count(nil), do: 0
  defp word_count(""), do: 0
  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end
