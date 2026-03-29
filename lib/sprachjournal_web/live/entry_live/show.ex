defmodule SprachjournalWeb.EntryLive.Show do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Journal

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    entry = Journal.get_entry!(id)
    {version, total} = Journal.version_info(entry)
    versions = Journal.get_versions(entry)

    {:ok,
     assign(socket,
       page_title: "Eintrag — #{Calendar.strftime(entry.inserted_at, "%d.%m.%Y")}",
       entry: entry,
       version: version,
       total_versions: total,
       versions: versions,
       confirm_delete: false
     )}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false)}
  end

  def handle_event("delete", _params, socket) do
    case Journal.soft_delete_entry(socket.assigns.entry) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> put_flash(:info, "Eintrag gelöscht.")
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Konnte nicht gelöscht werden.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-1">
            Eintrag
          </p>
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            {Calendar.strftime(@entry.inserted_at, "%d.%m.%Y")}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-xs font-mono">
          <span :if={@entry.completed_at} class="px-2 py-1 block-green uppercase">Fertig</span>
          <span :if={is_nil(@entry.completed_at)} class="px-2 py-1 block-orange uppercase">
            Entwurf
          </span>
          <span class="text-base-content/60">{Journal.word_count(@entry)} Wörter</span>
        </div>
      </div>

      <%!-- Version navigation --%>
      <div :if={@total_versions > 1} class="flex flex-wrap items-center gap-2 text-sm font-mono">
        <span class="font-bold">v{@version} von {@total_versions}</span>
        <%= for {v, idx} <- Enum.with_index(Enum.reverse(@versions), 1) do %>
          <.link
            :if={v.id != @entry.id}
            navigate={~p"/entries/#{v.id}"}
            class="brutal-btn px-2 py-1 block-cyan text-xs no-underline"
          >
            v{idx}
          </.link>
          <span :if={v.id == @entry.id} class="px-2 py-1 border-2 border-ink text-xs font-bold">
            v{idx}
          </span>
        <% end %>
      </div>

      <hr class="brutal-hr" />

      <%!-- Actions --%>
      <div class="flex flex-wrap items-center gap-3">
        <.link
          navigate={~p"/entries/#{@entry.id}/edit"}
          class="brutal-btn px-4 py-2 block-yellow text-sm no-underline"
        >
          Bearbeiten
        </.link>
        <.link
          :if={@entry.feedback}
          navigate={~p"/entries/#{@entry.id}/practice"}
          class={[
            "brutal-btn px-4 py-2 text-sm no-underline",
            if(@entry.practiced_at, do: "block-green", else: "block-blue")
          ]}
        >
          {if @entry.practiced_at, do: "✓ Geübt", else: "Üben"}
        </.link>
        <button
          :if={!@confirm_delete}
          phx-click="confirm_delete"
          class="brutal-btn px-4 py-2 block-dark text-sm"
        >
          Löschen
        </button>
        <div :if={@confirm_delete} class="flex items-center gap-2">
          <span class="text-xs font-mono text-bold-red">Wirklich löschen?</span>
          <button phx-click="delete" class="brutal-btn px-3 py-1 block-red text-xs">
            Ja
          </button>
          <button phx-click="cancel_delete" class="brutal-btn px-3 py-1 bg-base-200 text-xs">
            Nein
          </button>
        </div>
      </div>

      <div
        :if={@entry.prompt}
        class="text-sm font-mono text-base-content/60 border-l-4 border-ink pl-3"
      >
        Prompt: {@entry.prompt}
      </div>

      <%!-- Feedback (inline corrections) --%>
      <.feedback_view :if={@entry.feedback} feedback={@entry.feedback}>
        <:actions>
          <.link
            navigate={~p"/"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            &larr; Zurück
          </.link>
        </:actions>
      </.feedback_view>

      <%!-- No feedback yet --%>
      <div :if={is_nil(@entry.feedback)}>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 bg-base-300"></span> Dein Text
          </h2>
          <p class="font-mono text-sm whitespace-pre-wrap">{@entry.body}</p>
        </div>

        <.link
          navigate={~p"/"}
          class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg mt-6"
        >
          &larr; Zurück
        </.link>
      </div>
    </div>
    """
  end
end
