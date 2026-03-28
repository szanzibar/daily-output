defmodule SprachjournalWeb.HomeLive do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Journal
  alias Sprachjournal.Conversations
  alias Sprachjournal.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get_config()
    today_entry = Journal.get_today_entry()
    today_conversation = Conversations.get_today_conversation()
    recent_items = build_recent_items()
    streak = Journal.current_streak()

    {:ok,
     assign(socket,
       page_title: "Home",
       settings: settings,
       today_entry: today_entry,
       today_conversation: today_conversation,
       recent_items: recent_items,
       streak: streak
     )}
  end

  defp build_recent_items do
    entries =
      Journal.list_recent_entries(14)
      |> Enum.map(fn e ->
        %{
          type: :entry,
          id: e.id,
          preview: if(e.body, do: String.slice(e.body, 0..60), else: "(leer)"),
          completed: e.completed_at != nil,
          date: e.inserted_at,
          path: "/entries/#{e.id}",
          label: "Eintrag"
        }
      end)

    conversations =
      Conversations.list_recent_conversations(14)
      |> Enum.map(fn c ->
        %{
          type: :conversation,
          id: c.id,
          preview: c.topic || "(Gespräch)",
          completed: c.completed_at != nil,
          date: c.inserted_at,
          path: "/conversations/#{c.id}",
          label: "Gespräch"
        }
      end)

    (entries ++ conversations)
    |> Enum.sort_by(& &1.date, {:desc, DateTime})
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

      <%!-- CTAs --%>
      <div class="grid sm:grid-cols-2 gap-4">
        <%!-- Journal CTA --%>
        <div class="border-4 border-ink p-5 sm:p-6 block-yellow">
          <h2 class="text-xl sm:text-2xl font-black uppercase mb-2">
            {if(@today_entry, do: "Nochmal schreiben!", else: "Schreiben!")}
          </h2>
          <p class="text-sm mb-3 opacity-80">
            {if(@today_entry,
              do: "Neuer Eintrag mit frischen Prompts.",
              else: "Täglicher Journaleintrag."
            )}
          </p>
          <.link
            navigate={~p"/entries/new"}
            class="brutal-btn inline-block px-5 py-2 bg-ink text-paper text-sm no-underline"
          >
            Los geht's &rarr;
          </.link>
        </div>

        <%!-- Conversation CTA --%>
        <div class="border-4 border-ink p-5 sm:p-6 block-green">
          <h2 class="text-xl sm:text-2xl font-black uppercase mb-2">
            Gespräch!
          </h2>
          <p class="text-sm mb-3 opacity-80">
            Rollenspiel mit einem KI-Gesprächspartner.
          </p>
          <.link
            navigate={~p"/conversations/new"}
            class="brutal-btn inline-block px-5 py-2 bg-ink text-paper text-sm no-underline"
          >
            Starten &rarr;
          </.link>
        </div>
      </div>

      <%!-- Today's latest entry (clickable) --%>
      <.link
        :if={@today_entry}
        navigate={~p"/entries/#{@today_entry.id}"}
        class="block border-4 border-ink p-6 hover:bg-base-200 no-underline text-base-content"
      >
        <div class="flex items-start justify-between mb-3">
          <h2 class="text-xl font-black uppercase">Heute — Eintrag</h2>
          <div class="flex items-center gap-2">
            <span
              :if={@today_entry.completed_at}
              class="text-xs font-mono px-2 py-1 block-green uppercase"
            >
              Fertig
            </span>
            <span class="text-xs font-mono text-base-content/60">
              {Journal.word_count(@today_entry)} Wörter
            </span>
          </div>
        </div>
        <p class="font-mono text-sm line-clamp-3">{@today_entry.body}</p>
      </.link>

      <%!-- Today's latest conversation --%>
      <.link
        :if={@today_conversation}
        navigate={~p"/conversations/#{@today_conversation.id}"}
        class="block border-4 border-ink p-6 hover:bg-base-200 no-underline text-base-content"
      >
        <div class="flex items-start justify-between mb-3">
          <h2 class="text-xl font-black uppercase">Heute — Gespräch</h2>
          <span
            :if={@today_conversation.completed_at}
            class="text-xs font-mono px-2 py-1 block-green uppercase"
          >
            Fertig
          </span>
          <span
            :if={is_nil(@today_conversation.completed_at)}
            class="text-xs font-mono px-2 py-1 block-orange uppercase"
          >
            Offen
          </span>
        </div>
        <p class="font-mono text-sm line-clamp-2">{@today_conversation.topic || "(Freestyle)"}</p>
      </.link>

      <%!-- Recent history (interleaved entries + conversations) --%>
      <div :if={@recent_items != []}>
        <h2 class="text-xl font-black uppercase mb-3 flex items-center gap-2">
          <span class="inline-block w-3 h-3 block-blue"></span> Letzte Aktivität
        </h2>

        <div class="border-4 border-ink divide-y-2 divide-ink">
          <.link
            :for={item <- @recent_items}
            navigate={item.path}
            class="flex items-center justify-between px-4 py-3 hover:bg-base-200 no-underline text-base-content"
          >
            <div class="flex items-center gap-3 min-w-0">
              <span class={[
                "inline-block w-2 h-2 shrink-0",
                if(item.completed, do: "block-green", else: "block-orange")
              ]} />
              <span class={[
                "text-xs font-mono px-1.5 py-0.5 border-2 border-ink shrink-0",
                if(item.type == :conversation, do: "block-green", else: "block-yellow")
              ]}>
                {item.label}
              </span>
              <span class="font-mono text-sm truncate">
                {item.preview}
              </span>
            </div>
            <div class="flex items-center gap-3 shrink-0 ml-4">
              <span class="text-xs font-mono text-base-content/60">
                {Calendar.strftime(item.date, "%d.%m")}
              </span>
            </div>
          </.link>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@recent_items == [] and is_nil(@today_entry) and is_nil(@today_conversation)}
        class="text-center py-12"
      >
        <p class="text-lg font-mono text-base-content/50">
          Noch keine Einträge. Fang heute an!
        </p>
      </div>
    </div>
    """
  end
end
