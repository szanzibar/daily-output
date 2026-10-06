defmodule DailyOutputWeb.HistoryLive do
  @moduledoc "Every finished activity, newest first. Each links to its page, which shows the results."
  use DailyOutputWeb, :live_view

  alias DailyOutput.Activities

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("History"), activities: Activities.completed())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">{gettext("History")}</h1>
      <hr class="brutal-hr" />

      <div :if={@activities == []} id="history-empty" class="border-4 border-ink p-6 text-center">
        <p class="text-sm font-mono text-base-content/60">
          {gettext("Nothing here yet. Finished activities show up here.")}
        </p>
      </div>

      <div id="history" class="space-y-3">
        <.link
          :for={activity <- @activities}
          id={"activity-#{activity.id}"}
          navigate={activity_path(activity)}
          class="block border-4 border-ink p-4 no-underline text-base-content hover:bg-base-200"
        >
          <div class="flex flex-wrap items-center gap-2 mb-2">
            <span class="text-xs font-mono font-bold">
              {Calendar.strftime(activity.date, "%d.%m.%Y")}
            </span>
            <span class={[
              "text-xs font-black uppercase px-2 py-0.5 border-2 border-ink",
              if(activity.kind == "journal", do: "block-yellow", else: "block-pink")
            ]}>
              {if activity.kind == "journal", do: gettext("Journal"), else: gettext("Conversation")}
            </span>
          </div>
          <p :if={activity.focus["title"]} class="font-black leading-tight">
            {activity.focus["title"]}
          </p>
          <p :if={activity.summary} class="text-sm font-mono text-base-content/70 mt-1">
            {activity.summary}
          </p>
        </.link>
      </div>
    </div>
    """
  end
end
