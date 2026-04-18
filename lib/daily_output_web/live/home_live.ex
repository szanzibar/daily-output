defmodule DailyOutputWeb.HomeLive do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Journal
  alias DailyOutput.Conversations
  alias DailyOutput.Settings
  alias DailyOutput.FocusTopics

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get_config()
    today_entry = Journal.get_today_entry()
    today_conversation = Conversations.get_today_conversation()
    recent_days = build_recent_days()
    streak = FocusTopics.current_streak()
    challenge = FocusTopics.daily_challenge_status()

    {:ok,
     assign(socket,
       page_title: "Home",
       settings: settings,
       today_entry: today_entry,
       today_conversation: today_conversation,
       recent_days: recent_days,
       streak: streak,
       challenge: challenge
     )}
  end

  defp build_recent_days do
    entries =
      Journal.list_recent_entries(14)
      |> Enum.map(fn e ->
        completed = e.completed_at != nil and e.feedback != nil

        %{
          type: :entry,
          id: e.id,
          preview: if(e.body, do: String.slice(e.body, 0..60), else: gettext("(empty)")),
          completed: completed,
          date: e.inserted_at,
          path: if(e.feedback, do: "/entries/#{e.id}", else: "/entries/#{e.id}/edit"),
          label: gettext("Entry")
        }
      end)

    conversations =
      Conversations.list_recent_conversations(14)
      |> Enum.map(fn c ->
        completed = c.completed_at != nil and c.feedback != nil

        %{
          type: :conversation,
          id: c.id,
          preview: c.topic || gettext("(Conversation)"),
          completed: completed,
          date: c.inserted_at,
          path:
            if(c.feedback, do: "/conversations/#{c.id}", else: "/conversations/#{c.id}/continue"),
          label: gettext("Conversation")
        }
      end)

    (entries ++ conversations)
    |> Enum.sort_by(& &1.date, {:desc, DateTime})
    |> Enum.group_by(fn item -> DateTime.to_date(item.date) end)
    |> Enum.map(fn {date, items} ->
      day_done =
        Enum.any?(items, &(&1.type == :entry and &1.completed)) and
          Enum.any?(items, &(&1.type == :conversation and &1.completed))

      {date, items, day_done}
    end)
    |> Enum.sort_by(fn {date, _, _} -> date end, {:desc, Date})
    |> Enum.take(14)
  end

  defp challenge_icon(:complete), do: "✓"
  defp challenge_icon(:none), do: "○"

  defp challenge_bg(:complete), do: "block-green"
  defp challenge_bg(:none), do: "bg-base-200"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <%!-- Header: date + streak --%>
      <div class="flex flex-col sm:flex-row gap-4 sm:items-end sm:justify-between">
        <div>
          <p class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-1">
            {Calendar.strftime(Date.utc_today(), "%A")}
          </p>
          <h1 class="text-5xl sm:text-7xl font-black tracking-tighter uppercase leading-none">
            {Calendar.strftime(Date.utc_today(), "%d.%m.%Y")}
          </h1>
        </div>

        <div class="border-4 border-ink p-3 text-center">
          <div class="text-3xl sm:text-4xl font-black streak-active leading-none">
            {@streak}
          </div>
          <div class="text-xs font-mono uppercase tracking-widest">
            {ngettext("day streak", "days streak", max(@streak, 1))}
          </div>
        </div>
      </div>

      <hr class="brutal-hr" />

      <%!-- === HEUTE === --%>
      <div class={["border-4 border-ink", if(@challenge.all_done, do: "border-green", else: "")]}>
        <div :if={@challenge.all_done} class="block-green px-4 py-2 text-center">
          <span class="font-black uppercase text-sm tracking-widest">{gettext("Day complete!")}</span>
        </div>

        <%!-- Entry row --%>
        <.link
          :if={@today_entry}
          navigate={
            if(!is_nil(@today_entry.feedback),
              do: ~p"/entries/#{@today_entry.id}",
              else: ~p"/entries/#{@today_entry.id}/edit"
            )
          }
          class="block border-b-2 border-ink p-4 hover:bg-base-200 no-underline text-base-content cursor-pointer"
        >
          <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
            <div class="flex items-center gap-2">
              <span class={[
                "text-sm font-mono font-bold px-2 py-0.5 border-2 border-ink",
                challenge_bg(@challenge.entry)
              ]}>
                {challenge_icon(@challenge.entry)}
              </span>
              <span class="text-sm font-black uppercase px-2 py-0.5 border-2 border-ink block-yellow">
                {gettext("Entry")}
              </span>
            </div>
            <div class="flex flex-wrap items-center gap-2 pointer-events-auto">
              <span
                :if={@challenge.entry != :none}
                class="brutal-btn px-3 py-1 block-purple text-xs"
                onclick="event.preventDefault(); event.stopPropagation(); window.location.href='/entries/new'"
              >
                {gettext("+ New")}
              </span>
            </div>
          </div>
          <p class="font-mono text-sm text-base-content/70 line-clamp-2">{@today_entry.body}</p>
        </.link>
        <div :if={is_nil(@today_entry)} class="border-b-2 border-ink p-4">
          <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
            <div class="flex items-center gap-2">
              <span class="text-sm font-mono font-bold px-2 py-0.5 border-2 border-ink bg-base-200">
                ○
              </span>
              <span class="text-sm font-black uppercase px-2 py-0.5 border-2 border-ink block-yellow">
                {gettext("Entry")}
              </span>
            </div>
            <.link
              navigate={~p"/entries/new"}
              class="brutal-btn px-4 py-1.5 block-yellow text-xs no-underline"
            >
              {gettext("Write")} &rarr;
            </.link>
          </div>
          <p class="text-sm font-mono text-base-content/40">{gettext("No entry yet today.")}</p>
        </div>

        <%!-- Conversation row --%>
        <.link
          :if={@today_conversation}
          navigate={
            if(!is_nil(@today_conversation.feedback),
              do: ~p"/conversations/#{@today_conversation.id}",
              else: ~p"/conversations/#{@today_conversation.id}/continue"
            )
          }
          class="block p-4 hover:bg-base-200 no-underline text-base-content cursor-pointer"
        >
          <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
            <div class="flex items-center gap-2">
              <span class={[
                "text-sm font-mono font-bold px-2 py-0.5 border-2 border-ink",
                challenge_bg(@challenge.conversation)
              ]}>
                {challenge_icon(@challenge.conversation)}
              </span>
              <span class="text-sm font-black uppercase px-2 py-0.5 border-2 border-ink block-pink">
                {gettext("Conversation")}
              </span>
            </div>
            <div class="flex flex-wrap items-center gap-2 pointer-events-auto">
              <span
                :if={@challenge.conversation != :none}
                class="brutal-btn px-3 py-1 block-purple text-xs"
                onclick="event.preventDefault(); event.stopPropagation(); window.location.href='/conversations/new'"
              >
                {gettext("+ New")}
              </span>
            </div>
          </div>
          <p class="font-mono text-sm text-base-content/70 line-clamp-2">
            {@today_conversation.topic || "(Freestyle)"}
          </p>
        </.link>
        <div :if={is_nil(@today_conversation)} class="p-4">
          <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
            <div class="flex items-center gap-2">
              <span class="text-sm font-mono font-bold px-2 py-0.5 border-2 border-ink bg-base-200">
                ○
              </span>
              <span class="text-sm font-black uppercase px-2 py-0.5 border-2 border-ink block-pink">
                {gettext("Conversation")}
              </span>
            </div>
            <.link
              navigate={~p"/conversations/new"}
              class="brutal-btn px-4 py-1.5 block-pink text-xs no-underline"
            >
              {gettext("Start")} &rarr;
            </.link>
          </div>
          <p class="text-sm font-mono text-base-content/40">
            {gettext("No conversation yet today.")}
          </p>
        </div>
      </div>

      <%!-- === PAST DAYS === --%>
      <div :if={@recent_days != []}>
        <h2 class="text-xl font-black uppercase mb-3">
          {gettext("Activity")}
        </h2>

        <div class="space-y-3">
          <%= for {date, items, day_done} <- @recent_days do %>
            <div class={["border-4 border-ink", if(day_done, do: "border-green", else: "")]}>
              <div class={[
                "px-4 py-2 border-b-2 border-ink flex items-center justify-between",
                if(day_done, do: "block-green", else: "bg-base-200")
              ]}>
                <span class="text-sm font-black uppercase">
                  {Calendar.strftime(date, "%d.%m.%Y")}
                </span>
                <span :if={day_done} class="text-xs font-mono font-bold">✓</span>
              </div>

              <div class="divide-y divide-ink">
                <.link
                  :for={item <- items}
                  navigate={item.path}
                  class="flex items-center px-4 py-2.5 hover:bg-base-200 no-underline text-base-content gap-2"
                >
                  <span class={[
                    "text-xs font-mono font-bold px-2 py-0.5 border-2 border-ink shrink-0",
                    if(item.completed, do: "block-green", else: "bg-base-200")
                  ]}>
                    {if item.completed, do: "✓", else: "○"}
                  </span>
                  <span class={[
                    "text-xs font-mono font-bold px-2 py-0.5 border-2 border-ink shrink-0",
                    if(item.type == :conversation, do: "block-pink", else: "block-yellow")
                  ]}>
                    {item.label}
                  </span>
                  <span class="font-mono text-sm truncate">
                    {item.preview}
                  </span>
                </.link>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@recent_days == [] and is_nil(@today_entry) and is_nil(@today_conversation)}
        class="text-center py-12"
      >
        <p class="text-lg font-mono text-base-content/50">
          {gettext("No entries yet. Start today!")}
        </p>
      </div>
    </div>
    """
  end
end
