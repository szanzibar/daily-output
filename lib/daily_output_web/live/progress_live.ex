defmodule DailyOutputWeb.ProgressLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Stats

  @impl true
  def mount(_params, _session, socket) do
    overview = Stats.overview()

    # Scale for the trend bars; guard against an all-zero/nil week set.
    rates = overview.trend |> Enum.map(& &1.error_rate) |> Enum.reject(&is_nil/1)
    trend_max = Enum.max([1.0 | rates])
    time_max = Enum.max([1 | Enum.map(overview.time_days, & &1.total)])
    # Tiny guard so a quiet week still scales (cost is small floats, not big ints).
    usage_max = Enum.max([1.0e-9 | Enum.map(overview.usage_days, & &1.total)])

    {:ok,
     assign(socket,
       page_title: gettext("Progress"),
       overview: overview,
       trend_max: trend_max,
       time_max: time_max,
       usage_max: usage_max,
       purpose_colors: purpose_colors(overview.usage_by_purpose),
       has_data:
         overview.total_words > 0 or overview.total_time > 0 or
           overview.usage_total.cost > 0
     )}
  end

  defp bar_height(nil, _max), do: 0
  defp bar_height(rate, max), do: max(round(rate / max * 100), 4)

  # Stable color per feature for the cost bars + legend, assigned in cost order
  # (biggest spender first) so the palette stays consistent across the page.
  @purpose_palette ~w(block-blue block-green block-purple block-pink block-cyan block-yellow block-red block-dark)

  defp purpose_colors(by_purpose) do
    n = length(@purpose_palette)

    by_purpose
    |> Enum.with_index()
    |> Map.new(fn {%{purpose: purpose}, i} -> {purpose, Enum.at(@purpose_palette, rem(i, n))} end)
  end

  defp purpose_color(colors, purpose), do: Map.get(colors, purpose, "block-dark")

  defp dur(seconds), do: Stats.format_duration(seconds)

  defp cost(amount), do: Stats.format_cost(amount)

  defp purpose_label("proofread"), do: gettext("Proofreading")
  defp purpose_label("proofread_message"), do: gettext("Chat corrections")
  defp purpose_label("assessment"), do: gettext("Conversation review")
  defp purpose_label("conversation"), do: gettext("Conversation partner")
  defp purpose_label("flashcards"), do: gettext("Flashcards")
  defp purpose_label("prompts"), do: gettext("Writing prompts")
  defp purpose_label("openers"), do: gettext("Conversation openers")
  defp purpose_label("focus_summary"), do: gettext("Focus summaries")
  defp purpose_label(other), do: other |> String.replace("_", " ") |> String.capitalize()

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
          <.stat
            label={gettext("Total time")}
            value={Stats.format_duration(@overview.total_time)}
            class="block-pink"
          />
          <.stat
            label={gettext("AI spent")}
            value={cost(@overview.usage_total.cost)}
            class="block-orange"
          />
        </div>

        <%!-- Time tracking --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-1 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-cyan"></span> {gettext("Time")}
          </h2>
          <p class="text-xs font-mono text-base-content/60 mb-4">
            {gettext("Active time per section. Today, then the last 7 days.")}
          </p>

          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-5">
            <.recap label={gettext("Entry today")} value={dur(@overview.time_today.entry)} />
            <.recap label={gettext("Convo today")} value={dur(@overview.time_today.conversation)} />
            <.recap label={gettext("Cards today")} value={dur(@overview.time_today.flashcards)} />
            <.recap label={gettext("Total today")} value={dur(@overview.time_today.total)} />
          </div>

          <div class="flex items-end gap-1 sm:gap-2 h-40">
            <div
              :for={day <- @overview.time_days}
              class="flex-1 flex flex-col items-center gap-1 h-full justify-end"
            >
              <span class="text-[10px] sm:text-xs font-mono font-bold">
                {if day.total > 0, do: dur(day.total), else: "·"}
              </span>
              <div
                class={[
                  "w-full border-2 border-ink",
                  if(day.total > 0, do: "block-cyan", else: "bg-base-200")
                ]}
                style={"height: #{bar_height(day.total, @time_max)}%"}
                title={Calendar.strftime(day.date, "%d.%m")}
              >
              </div>
              <span class="text-[10px] font-mono text-base-content/50">
                {Calendar.strftime(day.date, "%a")}
              </span>
            </div>
          </div>
        </div>

        <%!-- AI cost --%>
        <div class="border-4 border-ink p-5">
          <h2 class="text-lg font-black uppercase mb-1 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-orange"></span> {gettext("AI cost")}
          </h2>
          <p class="text-xs font-mono text-base-content/60 mb-4">
            {gettext("Estimated Anthropic API spend per day, by feature. The last 7 days.")}
          </p>

          <div class="grid grid-cols-2 gap-3 mb-5">
            <.recap label={gettext("This week")} value={cost(@overview.usage_week.cost)} />
            <.recap label={gettext("All time")} value={cost(@overview.usage_total.cost)} />
          </div>

          <div class="flex items-end gap-1 sm:gap-2 h-40">
            <div
              :for={day <- @overview.usage_days}
              class="flex-1 flex flex-col items-center gap-1 h-full justify-end"
            >
              <span class="text-[10px] sm:text-xs font-mono font-bold">
                {if day.total > 0, do: cost(day.total), else: "·"}
              </span>
              <div
                class={[
                  "w-full border-2 border-ink flex flex-col-reverse",
                  if(day.total > 0, do: "", else: "bg-base-200")
                ]}
                style={"height: #{bar_height(day.total, @usage_max)}%"}
                title={Calendar.strftime(day.date, "%d.%m")}
              >
                <div
                  :for={seg <- day.by_purpose}
                  class={["w-full", purpose_color(@purpose_colors, seg.purpose)]}
                  style={"height: #{seg.cost / day.total * 100}%"}
                  title={"#{purpose_label(seg.purpose)}: #{cost(seg.cost)}"}
                >
                </div>
              </div>
              <span class="text-[10px] font-mono text-base-content/50">
                {Calendar.strftime(day.date, "%a")}
              </span>
            </div>
          </div>

          <%!-- Legend — all-time spend per feature, colors match the bars. --%>
          <div :if={@overview.usage_by_purpose != []} class="space-y-2 mt-5">
            <div
              :for={row <- @overview.usage_by_purpose}
              class="flex items-baseline justify-between gap-3 border-2 border-ink px-3 py-2"
            >
              <span class="flex items-center gap-2 min-w-0">
                <span class={[
                  "inline-block w-3 h-3 border border-ink shrink-0",
                  purpose_color(@purpose_colors, row.purpose)
                ]}>
                </span>
                <span class="text-xs font-mono font-bold uppercase tracking-wide truncate">
                  {purpose_label(row.purpose)}
                </span>
              </span>
              <div class="flex items-baseline gap-3 shrink-0">
                <span class="text-[10px] font-mono text-base-content/50">
                  {row.calls} {gettext("calls")}
                </span>
                <span class="text-sm font-black">{cost(row.cost)}</span>
              </div>
            </div>
          </div>
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
