defmodule SprachjournalWeb.EntryLive.Practice do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Journal
  alias Sprachjournal.Practice

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    entry = Journal.get_entry!(id)
    target = Practice.extract_corrected_text(entry.feedback && entry.feedback["annotated_text"])

    {:ok,
     assign(socket,
       page_title: "Üben",
       entry: entry,
       target: target,
       typed: "",
       result: Practice.compare_chars("", target)
     )}
  end

  @impl true
  def handle_event("typing", %{"practice" => %{"text" => typed}}, socket) do
    result = Practice.compare_chars(typed, socket.assigns.target)
    socket = assign(socket, typed: typed, result: result)

    if result.completed and is_nil(socket.assigns.entry.practiced_at) do
      {:ok, entry} = Practice.mark_entry_practiced(socket.assigns.entry)
      {:noreply, assign(socket, entry: entry)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-3xl sm:text-4xl font-black tracking-tighter uppercase">
          Üben
        </h1>
        <span class="text-sm font-mono text-base-content/60">
          {@result.progress}/{@result.total}
        </span>
      </div>

      <hr class="brutal-hr" />

      <%!-- Progress bar --%>
      <div class="border-3 border-ink h-4 bg-base-200">
        <div
          class={["h-full transition-all", if(@result.completed, do: "block-green", else: "block-blue")]}
          style={"width: #{if @result.total > 0, do: round(@result.progress / @result.total * 100), else: 0}%"}
        />
      </div>

      <%!-- Completed --%>
      <div :if={@result.completed} class="border-4 border-ink p-6 block-green text-center">
        <h2 class="text-3xl font-black uppercase mb-2">Geschafft!</h2>
        <p class="text-sm opacity-80">Fehlerfrei abgeschrieben.</p>
        <.link
          navigate={~p"/entries/#{@entry.id}"}
          class="brutal-btn inline-block px-6 py-3 bg-ink text-paper text-lg no-underline mt-4"
        >
          Zurück
        </.link>
      </div>

      <%!-- Practice area: overlay textarea on ghost text --%>
      <div :if={!@result.completed} class="border-4 border-ink p-5">
        <div class="practice-overlay-container">
          <%!-- Ghost layer: styled characters --%>
          <div class="practice-ghost" aria-hidden="true">
            <%= for {char, status} <- @result.compared do %><span class={if status == :correct, do: "practice-correct", else: "practice-wrong"}>{char}</span><% end %><span class="practice-cursor">|</span><span class="practice-remaining">{@result.remaining}</span>
          </div>

          <%!-- Input layer: transparent textarea on top --%>
          <.form for={%{}} phx-change="typing" class="practice-form">
            <textarea
              name="practice[text]"
              class="practice-textarea"
              autofocus
              spellcheck="false"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
            >{@typed}</textarea>
          </.form>
        </div>
      </div>

      <.link
        navigate={~p"/entries/#{@entry.id}"}
        class="brutal-btn inline-block px-4 py-2 bg-base-200 no-underline text-sm"
      >
        &larr; Zurück
      </.link>
    </div>
    """
  end
end
