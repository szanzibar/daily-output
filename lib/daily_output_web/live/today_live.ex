defmodule DailyOutputWeb.TodayLive do
  @moduledoc """
  `/` asks `Today.next_step/0` and sends you to that step, or shows the done screen. Steps
  only ever navigate back here, so the flow lives in `Today` alone.

  The celebration fires here, once per day and status, because the browser remembers it
  in localStorage.
  """
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Clock, Streak, Today}

  @impl true
  def mount(_params, _session, socket) do
    # Replace, so Back from a step skips `/` instead of bouncing straight forward again.
    case Today.next_step() do
      {:activity, activity} ->
        {:ok, push_navigate(socket, to: activity_path(activity), replace: true)}

      :cards ->
        {:ok, push_navigate(socket, to: ~p"/flashcards", replace: true)}

      :done ->
        streak = Today.streak()
        {still_due, _queue} = Today.extra_practice()

        {:ok,
         assign(socket,
           page_title: gettext("Today"),
           streak: streak,
           freezes_full?: streak.freezes_available >= Streak.max_freezes(),
           still_due: still_due,
           today: Clock.today()
         )}
    end
  end

  @impl true
  def handle_event("bonus", _params, socket) do
    Today.start_bonus()
    {:noreply, push_navigate(socket, to: ~p"/", replace: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        {gettext("Done for today")}
      </h1>
      <hr class="brutal-hr" />

      <div
        id="streak"
        class="border-4 border-ink p-5 sm:p-6 flex flex-wrap items-end justify-between gap-4"
      >
        <div>
          <p class="text-6xl sm:text-7xl font-black leading-none streak-active">{@streak.count}</p>
          <p class="text-xs font-mono uppercase tracking-widest mt-2">
            {ngettext("day in a row", "days in a row", @streak.count)}
          </p>
        </div>
        <div id="freezes" class="text-right">
          <p :if={@streak.freezes_available > 0} class="text-2xl leading-none" aria-hidden="true">
            {String.duplicate("❄", @streak.freezes_available)}
          </p>
          <p class="text-xs font-mono uppercase tracking-widest mt-2 text-base-content/60">
            {ngettext(
              "%{count} streak freeze",
              "%{count} streak freezes",
              @streak.freezes_available
            )}
          </p>
        </div>
      </div>

      <%!-- Side by side while both labels fit on one line, stacked otherwise. One alone takes
           the row. --%>
      <div id="offers" class="flex flex-wrap gap-4">
        <div
          :if={@streak.today_status == :bonus}
          id="bonus-done"
          class="grow basis-42 border-4 border-ink p-4 sm:p-5 block-green"
        >
          <p class="text-sm sm:text-lg font-black uppercase">{gettext("Bonus done")}</p>
          <p :if={!@freezes_full?} class="text-xs font-mono mt-1">{gettext("+1 streak freeze")}</p>
          <p :if={@freezes_full?} id="freezes-full" class="text-xs font-mono mt-1">
            {gettext("Your streak freezes are full.")}
          </p>
        </div>
        <button
          :if={@streak.today_status == :passed}
          id="bonus"
          type="button"
          phx-click="bonus"
          class="brutal-btn grow basis-42 p-4 sm:p-5 block-yellow text-left"
        >
          <span class="block text-sm sm:text-lg">{gettext("Bonus round")}</span>
          <span class="block text-xs font-mono normal-case tracking-normal opacity-70 mt-1">
            {if @freezes_full?, do: gettext("Freezes full"), else: gettext("+1 streak freeze")}
          </span>
        </button>
        <.link
          :if={@still_due > 0}
          id="practice-more"
          navigate={~p"/flashcards/more"}
          class="brutal-btn grow basis-42 p-4 sm:p-5 block-pink text-left no-underline"
        >
          <span class="block text-sm sm:text-lg">{gettext("More cards")}</span>
          <span class="block text-xs font-mono normal-case tracking-normal opacity-70 mt-1">
            {ngettext("%{count} card due", "%{count} cards due", @still_due)}
          </span>
        </.link>
      </div>

      <div
        id="celebrate"
        phx-hook=".Celebrate"
        data-key={"#{@today}-#{@streak.today_status}"}
        data-message={
          if @streak.today_status == :bonus,
            do: gettext("Bonus done!"),
            else: gettext("Day complete!")
        }
        class="hidden"
      >
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Celebrate">
        // One key per day and status piles up in localStorage. Known and accepted.
        export default {
          mounted() {
            const key = `celebrated:${this.el.dataset.key}`
            if (localStorage.getItem(key)) return
            localStorage.setItem(key, "1")
            window.dispatchEvent(new CustomEvent("celebrate", {detail: {message: this.el.dataset.message}}))
          }
        }
      </script>
    </div>
    """
  end
end
