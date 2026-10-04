defmodule DailyOutputWeb.TodayLive do
  @moduledoc "Placeholder until phase 4: shows which step `Today.next_step/0` picked."
  use DailyOutputWeb, :live_view

  alias DailyOutput.Today

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Today"), step: Today.next_step())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">{gettext("Today")}</h1>
      <hr class="brutal-hr" />
      <%= case @step do %>
        <% {:activity, activity} -> %>
          <p id="today-activity" data-kind={activity.kind} class="text-xl font-black uppercase">
            {if activity.kind == "journal", do: gettext("Entry"), else: gettext("Conversation")}
          </p>
        <% :cards -> %>
          <.link
            id="today-cards"
            navigate={~p"/flashcards"}
            class="brutal-btn inline-block px-6 py-3 block-cyan no-underline"
          >
            {gettext("Cards")} &rarr;
          </.link>
        <% :done -> %>
          <p id="today-done" class="text-xl font-black uppercase">{gettext("Day complete!")}</p>
      <% end %>
    </div>
    """
  end
end
