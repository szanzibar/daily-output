defmodule SprachjournalWeb.HomeLive do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Journal
  alias Sprachjournal.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get_config()
    today_entry = Journal.get_today_entry()
    recent_entries = Journal.list_recent_entries(14)
    streak = Journal.current_streak()

    {:ok,
     assign(socket,
       page_title: "Home",
       settings: settings,
       today_entry: today_entry,
       recent_entries: recent_entries,
       streak: streak
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <%!-- Today's header block --%>
      <div class="flex flex-col sm:flex-row gap-4 sm:items-end sm:justify-between">
        <div>
          <p class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-1">
            {Calendar.strftime(Date.utc_today(), "%A")}
          </p>
          <h1 class="text-5xl sm:text-7xl font-black tracking-tighter uppercase leading-none">
            {Calendar.strftime(Date.utc_today(), "%d.%m.%Y")}
          </h1>
        </div>

        <div class="flex items-center gap-4">
          <div :if={@streak > 0} class="text-right">
            <div class="text-3xl sm:text-4xl font-black streak-active leading-none">
              {@streak}
            </div>
            <div class="text-xs font-mono uppercase tracking-widest">
              {ngettext("Tag", "Tage", @streak)} Streak
            </div>
          </div>
        </div>
      </div>

      <hr class="brutal-hr" />

      <%!-- Always show write CTA --%>
      <div class="border-4 border-ink p-6 sm:p-8 block-yellow">
        <h2 class="text-2xl sm:text-3xl font-black uppercase mb-3">
          {if(@today_entry, do: "Nochmal schreiben!", else: "Zeit zu schreiben!")}
        </h2>
        <p class="text-sm mb-4 opacity-80">
          {if @today_entry do
            "Start a new entry with fresh prompts."
          else
            "Start your daily journal entry. Write in #{@settings.target_language || "de"} for #{@settings.timer_minutes || 5} minutes."
          end}
        </p>
        <.link
          navigate={~p"/entries/new"}
          class="brutal-btn inline-block px-6 py-3 bg-ink text-paper text-lg no-underline"
        >
          Los geht's &rarr;
        </.link>
      </div>

      <%!-- Today's latest entry (clickable) --%>
      <.link
        :if={@today_entry}
        navigate={~p"/entries/#{@today_entry.id}"}
        class="block border-4 border-ink p-6 hover:bg-base-200 no-underline text-base-content"
      >
        <div class="flex items-start justify-between mb-3">
          <h2 class="text-xl font-black uppercase">Heute</h2>
          <div class="flex items-center gap-2">
            <span
              :if={@today_entry.completed_at}
              class="text-xs font-mono px-2 py-1 block-green uppercase"
            >
              Fertig
            </span>
            <span
              :if={is_nil(@today_entry.completed_at)}
              class="text-xs font-mono px-2 py-1 block-orange uppercase"
            >
              Entwurf
            </span>
            <span class="text-xs font-mono text-base-content/60">
              {Journal.word_count(@today_entry)} Wörter
            </span>
          </div>
        </div>
        <p class="font-mono text-sm line-clamp-3">{@today_entry.body}</p>
      </.link>

      <%!-- Recent history (excludes today) --%>
      <div :if={@recent_entries != []}>
        <h2 class="text-xl font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-blue"></span> Letzte Einträge
        </h2>

        <div class="border-4 border-ink divide-y-2 divide-ink">
          <.link
            :for={entry <- @recent_entries}
            navigate={~p"/entries/#{entry.id}"}
            class="flex items-center justify-between px-4 py-3 hover:bg-base-200 no-underline text-base-content"
          >
            <div class="flex items-center gap-3 min-w-0">
              <span class={[
                "inline-block w-2 h-2 shrink-0",
                if(entry.completed_at, do: "block-green", else: "block-orange")
              ]} />
              <span class="font-mono text-sm truncate">
                {if(entry.body, do: String.slice(entry.body, 0..60), else: "(leer)")}
              </span>
            </div>
            <div class="flex items-center gap-3 shrink-0 ml-4">
              <span class="text-xs font-mono text-base-content/60">
                {Journal.word_count(entry)}w
              </span>
              <span class="text-xs font-mono text-base-content/60">
                {Calendar.strftime(entry.inserted_at, "%d.%m")}
              </span>
            </div>
          </.link>
        </div>
      </div>

      <%!-- Empty state --%>
      <div :if={@recent_entries == [] and is_nil(@today_entry)} class="text-center py-12">
        <p class="text-lg font-mono text-base-content/50">
          Noch keine Einträge. Fang heute an!
        </p>
      </div>
    </div>
    """
  end
end
