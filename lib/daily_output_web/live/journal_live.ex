defmodule DailyOutputWeb.JournalLive do
  @moduledoc """
  One page for a journal entry: write, finish, and results.

  The draft autosaves as you type. Finish shows up once the TimeTracker hook has logged
  enough active time today (`Today.journal_seconds_left/1`), so the countdown only runs
  while you're writing.
  """
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Activities, Clock, Stats, Today}
  alias DailyOutputWeb.TranslatableText

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Activities.get!(id)

    socket =
      socket
      |> assign(
        page_title: gettext("Journal"),
        activity: activity,
        today?: activity.date == Clock.today(),
        running: nil,
        failed: nil
      )
      |> count_down()

    if connected?(socket) and is_nil(activity.prompt) and is_nil(activity.completed_at),
      do: {:ok, run(socket, :prepare)},
      else: {:ok, socket}
  end

  @impl true
  def handle_event("draft", %{"body" => body}, socket) do
    {:noreply,
     assign(socket, activity: Activities.update(socket.assigns.activity, %{body: body}))}
  end

  def handle_event("finish", %{"body" => body}, socket) do
    socket = assign(socket, activity: Activities.update(socket.assigns.activity, %{body: body}))
    if String.trim(body) == "", do: {:noreply, socket}, else: {:noreply, run(socket, :finish)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, run(socket, socket.assigns.failed)}

  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    Stats.track(section, seconds)
    {:noreply, count_down(socket)}
  end

  @impl true
  def handle_async(_call, {:ok, {:ok, activity}}, socket) do
    {:noreply, assign(socket, activity: activity, running: nil)}
  end

  def handle_async(call, _result, socket) do
    {:noreply, assign(socket, running: nil, failed: call)}
  end

  defp run(socket, call) do
    activity = socket.assigns.activity
    socket = assign(socket, running: call, failed: nil)

    case call do
      :prepare -> start_async(socket, :prepare, fn -> Today.prepare(activity) end)
      :finish -> start_async(socket, :finish, fn -> Today.finish(activity) end)
    end
  end

  defp count_down(socket) do
    logged = Stats.time_for_day(socket.assigns.activity.date).journal
    assign(socket, seconds_left: Today.journal_seconds_left(logged))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto space-y-4">
      <div
        :if={is_nil(@activity.completed_at)}
        id="journal-time-tracker"
        phx-hook="TimeTracker"
        data-section="journal"
        data-seconds-left={@seconds_left}
        data-countdown="finish-countdown-time"
        class="hidden"
      >
      </div>

      <.activity_header title={gettext("Journal")} activity={@activity} today={@today?} />
      <.focus_banner focus={@activity.focus} />

      <div :if={@activity.prompt} id="prompt" class="border-l-4 border-ink pl-4 text-lg font-bold">
        <.live_component module={TranslatableText} id="translate-prompt" text={@activity.prompt} />
      </div>

      <%= cond do %>
        <% @activity.completed_at -> %>
          <div id="results" class="space-y-4">
            <div class="border-4 border-ink p-4">
              <h2 class="text-lg font-black uppercase mb-4 flex items-center gap-2">
                <span class="inline-block w-3 h-3 block-red"></span> {gettext("Corrections")}
              </h2>
              <.annotated_text id="journal-corrections" feedback={@activity.feedback} />
            </div>
            <.focus_result_box result={@activity.feedback["focus_result"]} />
            <.results_nav today={@today?} />
          </div>
        <% is_nil(@activity.prompt) -> %>
          <.preparing
            failed={@failed == :prepare}
            message={gettext("Picking today's focus and writing your prompt")}
          />
        <% @running == :finish -> %>
          <div id="finish-loading">
            <.retro_loader message={gettext("Your text is being reviewed")} />
          </div>
        <% true -> %>
          <form id="journal-form" phx-change="draft" phx-submit="finish" class="space-y-3">
            <%!-- The hook owns the text, so a re-render never resets what you typed. --%>
            <textarea
              id="journal-editor"
              name="body"
              phx-hook="AutoExpand"
              phx-update="ignore"
              phx-debounce="1000"
              data-persist-key={"journal-#{@activity.id}"}
              data-no-enter-submit
              placeholder={gettext("Start writing...")}
              class="journal-editor"
            >{@activity.body}</textarea>
            <div class="flex flex-wrap items-center justify-end gap-3">
              <%!-- The hook ticks the time down between reports, so the server leaves it be. --%>
              <span
                :if={@seconds_left > 0}
                id="finish-countdown"
                class="timer-display text-sm text-base-content/50"
              >
                {gettext("Finish in")}
                <span id="finish-countdown-time" phx-update="ignore">
                  {Calendar.strftime(Time.from_seconds_after_midnight(@seconds_left), "%-M:%S")}
                </span>
              </span>
              <button
                :if={@seconds_left == 0}
                id="finish"
                type="submit"
                disabled={String.trim(@activity.body || "") == ""}
                class="brutal-btn px-6 py-3 text-lg block-green disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {gettext("Finish")} &check;
              </button>
            </div>
            <.ai_error
              :if={@failed == :finish}
              id="finish-error"
              message={gettext("Couldn't review your text.")}
            />
          </form>
      <% end %>
    </div>
    """
  end
end
