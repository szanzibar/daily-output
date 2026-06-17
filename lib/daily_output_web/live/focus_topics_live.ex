defmodule DailyOutputWeb.FocusTopicsLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.FocusTopics

  @impl true
  def mount(_params, _session, socket) do
    active = FocusTopics.list_active_topics()
    mastered = FocusTopics.list_all_topics() |> Enum.filter(& &1.mastered_at)

    {:ok,
     assign(socket,
       page_title: gettext("Focus Pool"),
       active_topics: active,
       mastered_topics: mastered,
       show_mastered: false
     )}
  end

  @impl true
  def handle_event("master_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    {:ok, _} = FocusTopics.master_topic(topic)
    {:noreply, reload(socket)}
  end

  def handle_event("delete_topic", %{"id" => id}, socket) do
    topic = FocusTopics.get_topic!(String.to_integer(id))
    {:ok, _} = FocusTopics.delete_topic(topic)
    {:noreply, reload(socket)}
  end

  def handle_event("toggle_mastered", _params, socket) do
    {:noreply, assign(socket, show_mastered: !socket.assigns.show_mastered)}
  end

  defp reload(socket) do
    active = FocusTopics.list_active_topics()
    mastered = FocusTopics.list_all_topics() |> Enum.filter(& &1.mastered_at)
    assign(socket, active_topics: active, mastered_topics: mastered)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        {gettext("Focus Pool")}
      </h1>

      <hr class="brutal-hr" />

      <p class="text-sm font-mono text-base-content/60">
        {gettext(
          "Topics from your feedback tips to focus on while writing and speaking. Choose a focus topic before each entry or conversation."
        )}
      </p>

      <%!-- Active topics --%>
      <div :if={@active_topics != []} class="border-4 border-ink divide-y-2 divide-ink">
        <div :for={topic <- @active_topics} class="p-4 flex items-start justify-between gap-3">
          <div class="flex-1">
            <.rich_text text={topic.text} class="text-sm" />
            <p class="text-xs font-mono text-base-content/50 mt-1">
              {topic.source_type} — {Calendar.strftime(topic.inserted_at, "%d.%m.%Y")}
            </p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button
              phx-click="master_topic"
              phx-value-id={topic.id}
              class="brutal-btn px-3 py-1 block-green text-xs"
            >
              {gettext("Mastered")}
            </button>
            <button
              phx-click="delete_topic"
              phx-value-id={topic.id}
              class="brutal-btn px-2 py-1 block-dark text-xs"
            >
              &times;
            </button>
          </div>
        </div>
      </div>

      <div :if={@active_topics == []} class="border-4 border-ink p-6 text-center">
        <p class="text-sm font-mono text-base-content/50">
          {gettext("No focus topics yet. Add tips from your feedback!")}
        </p>
      </div>

      <%!-- Mastered topics (collapsible) --%>
      <div :if={@mastered_topics != []}>
        <button
          phx-click="toggle_mastered"
          class="text-sm font-mono text-base-content/50 hover:text-base-content cursor-pointer"
        >
          {if @show_mastered, do: "▼", else: "▶"} {gettext("%{count} mastered topics",
            count: length(@mastered_topics)
          )}
        </button>

        <div :if={@show_mastered} class="border-4 border-ink divide-y divide-ink mt-2 opacity-60">
          <div :for={topic <- @mastered_topics} class="p-3 flex items-start justify-between gap-3">
            <div class="flex-1">
              <.rich_text text={topic.text} class="text-sm line-through" />
              <p class="text-xs font-mono text-base-content/40 mt-1">
                {gettext("Mastered on %{date}",
                  date: Calendar.strftime(topic.mastered_at, "%d.%m.%Y")
                )}
              </p>
            </div>
            <button
              phx-click="delete_topic"
              phx-value-id={topic.id}
              class="brutal-btn px-2 py-1 block-dark text-xs shrink-0"
            >
              &times;
            </button>
          </div>
        </div>
      </div>

      <.link
        navigate={~p"/"}
        class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
      >
        &larr; {gettext("Back")}
      </.link>
    </div>
    """
  end
end
