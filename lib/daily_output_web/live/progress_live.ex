defmodule DailyOutputWeb.ProgressLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Stats

  @impl true
  def mount(_params, _session, socket) do
    overview = Stats.overview()

    # Scale for the trend bars; guard against an all-zero/nil week set.
    rates = overview.trend |> Enum.map(& &1.error_rate) |> Enum.reject(&is_nil/1)
    trend_max = Enum.max([1.0 | rates])

    {:ok,
     assign(socket,
       page_title: gettext("Progress"),
       overview: overview,
       trend_max: trend_max,
       has_data: overview.total_words > 0
     )}
  end

  defp bar_height(nil, _max), do: 0
  defp bar_height(rate, max), do: max(round(rate / max * 100), 4)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
        {gettext("Progress")}
      </h1>

      <hr class="brutal-hr" />

      <div :if={!@has_data} class="border-4 border-ink p-6 text-center">
        <p class="text-sm font-mono text-base-content/60">
          {gettext("Finish an entry or conversation to start tracking your progress.")}
        </p>
      </div>

      <div :if={@has_data} class="space-y-6">
        <%!-- Lifetime totals --%>
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <.stat label={gettext("Words written")} value={@overview.total_words} class="block-yellow" />
          <.stat label={gettext("Active days")} value={@overview.active_days} class="block-cyan" />
          <.stat
            label={gettext("Focus mastered")}
            value={@overview.focus_mastered}
            class="block-green"
          />
          <.stat label={gettext("Entries")} value={@overview.entries} class="bg-base-100" />
          <.stat
            label={gettext("Conversations")}
            value={@overview.conversations}
            class="bg-base-100"
          />
        </div>

        <%!-- Error-rate trend --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-1 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-red"></span> {gettext("Mistakes over time")}
          </h2>
          <p class="text-xs font-mono text-base-content/60 mb-4">
            {gettext("Corrections per 100 words, by week. Lower is better ↓")}
          </p>

          <div class="flex items-end gap-1 sm:gap-2 h-40">
            <div
              :for={week <- @overview.trend}
              class="flex-1 flex flex-col items-center gap-1 h-full justify-end"
            >
              <span class="text-[10px] sm:text-xs font-mono font-bold">
                {if week.error_rate, do: week.error_rate, else: "·"}
              </span>
              <div
                class={[
                  "w-full border-2 border-ink",
                  if(week.error_rate, do: "block-purple", else: "bg-base-200")
                ]}
                style={"height: #{bar_height(week.error_rate, @trend_max)}%"}
                title={Calendar.strftime(week.finish, "%d.%m")}
              >
              </div>
              <span class="text-[10px] font-mono text-base-content/50">
                {Calendar.strftime(week.finish, "%d.%m")}
              </span>
            </div>
          </div>
        </div>

        <%!-- This week recap --%>
        <div class="border-4 border-ink p-5 block-purple">
          <h2 class="text-lg font-black uppercase mb-3">{gettext("This week")}</h2>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <.recap label={gettext("Days")} value={@overview.recap.days_active} />
            <.recap label={gettext("Words")} value={@overview.recap.words} />
            <.recap
              label={gettext("Mistakes/100")}
              value={if @overview.recap.error_rate, do: @overview.recap.error_rate, else: "—"}
            />
            <.recap label={gettext("Focus mastered")} value={@overview.recap.focus_mastered} />
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

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class={["border-4 border-ink p-4 text-center", @class]}>
      <div class="text-3xl font-black leading-none">{@value}</div>
      <div class="text-xs font-mono uppercase tracking-widest mt-1">{@label}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp recap(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-2xl font-black leading-none">{@value}</div>
      <div class="text-[10px] font-mono uppercase tracking-widest mt-1">{@label}</div>
    </div>
    """
  end
end
