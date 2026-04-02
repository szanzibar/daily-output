defmodule DailyOutputWeb.EntryLive.Show do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Journal

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    entry = Journal.get_entry!(id)
    {version, total} = Journal.version_info(entry)
    versions = Journal.get_versions(entry)

    focus_mastered =
      if entry.focus_topic_id do
        topic = DailyOutput.FocusTopics.get_topic!(entry.focus_topic_id)
        topic.mastered_at != nil
      else
        false
      end

    {:ok,
     assign(socket,
       page_title:
         gettext("Entry — %{date}", date: Calendar.strftime(entry.inserted_at, "%d.%m.%Y")),
       entry: entry,
       version: version,
       total_versions: total,
       versions: versions,
       confirm_delete: false,
       focus_pool_texts: DailyOutput.FocusTopics.active_source_texts(),
       focus_mastered: focus_mastered
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
         |> put_flash(:info, gettext("Entry deleted."))
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete."))}
    end
  end

  def handle_event("add_focus_topic", params, socket) do
    alias DailyOutput.{FocusTopics, AI}
    raw_text = params["text"]

    # Summarize the tip into a concise, generic focus point
    summarized =
      case AI.summarize_focus_topic(raw_text) do
        {:ok, text} -> text
        {:error, _} -> raw_text
      end

    FocusTopics.create_topic(%{
      text: summarized,
      source_text: raw_text,
      source_type: params["source_type"],
      source_id: String.to_integer(params["source_id"])
    })

    {:noreply, assign(socket, focus_pool_texts: FocusTopics.active_source_texts())}
  end

  def handle_event("master_focus_topic", _params, socket) do
    alias DailyOutput.FocusTopics
    entry = socket.assigns.entry

    if entry.focus_topic_id do
      topic = FocusTopics.get_topic!(entry.focus_topic_id)
      {:ok, _} = FocusTopics.master_topic(topic)

      {:noreply,
       assign(socket,
         focus_mastered: true,
         focus_pool_texts: FocusTopics.active_source_texts()
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("override_focus_result", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Overridden — counts as used."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-1">
            {gettext("Entry")}
          </p>
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            {Calendar.strftime(@entry.inserted_at, "%d.%m.%Y")}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-xs font-mono">
          <span :if={@entry.completed_at} class="px-2 py-1 block-green uppercase">
            {gettext("Done")}
          </span>
          <span :if={is_nil(@entry.completed_at)} class="px-2 py-1 block-orange uppercase">
            {gettext("Draft")}
          </span>
          <span class="text-base-content/60">{Journal.word_count(@entry)} {gettext("words")}</span>
        </div>
      </div>

      <%!-- Version navigation --%>
      <div :if={@total_versions > 1} class="flex flex-wrap items-center gap-2 text-sm font-mono">
        <span class="font-bold">
          {gettext("v%{version} of %{total}", version: @version, total: @total_versions)}
        </span>
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
          {gettext("Edit")}
        </.link>
        <button
          :if={!@confirm_delete}
          phx-click="confirm_delete"
          class="brutal-btn px-4 py-2 block-dark text-sm"
        >
          {gettext("Delete")}
        </button>
        <div :if={@confirm_delete} class="flex items-center gap-2">
          <span class="text-xs font-mono text-bold-red">{gettext("Really delete?")}</span>
          <button phx-click="delete" class="brutal-btn px-3 py-1 block-red text-xs">
            {gettext("Yes")}
          </button>
          <button phx-click="cancel_delete" class="brutal-btn px-3 py-1 bg-base-200 text-xs">
            {gettext("No")}
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
      <.feedback_view
        :if={@entry.feedback}
        feedback={@entry.feedback}
        source_type="entry"
        source_id={@entry.id}
        focus_pool_texts={@focus_pool_texts}
        focus_mastered={@focus_mastered}
      >
        <:actions>
          <.link
            navigate={~p"/"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            &larr; {gettext("Back")}
          </.link>
        </:actions>
      </.feedback_view>

      <%!-- No feedback yet --%>
      <div :if={is_nil(@entry.feedback)}>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 bg-base-300"></span> {gettext("Your Text")}
          </h2>
          <p class="font-mono text-sm whitespace-pre-wrap">{@entry.body}</p>
        </div>

        <.link
          navigate={~p"/"}
          class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg mt-6"
        >
          &larr; {gettext("Back")}
        </.link>
      </div>
    </div>
    """
  end
end
