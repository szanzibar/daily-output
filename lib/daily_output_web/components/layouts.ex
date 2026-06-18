defmodule DailyOutputWeb.Layouts do
  @moduledoc """
  Layout components for DailyOutput.
  """
  use DailyOutputWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="border-b-4 border-ink block-blue">
        <div class="px-4 sm:px-6 lg:px-8 py-3 flex flex-wrap items-center justify-between gap-2">
          <a href="/" class="no-underline text-white">
            <span class="text-xl sm:text-3xl font-black tracking-tighter uppercase">
              DAILY<span class="block-yellow text-ink px-1">OUTPUT</span>
            </span>
          </a>

          <%!-- CSS-only toggle: hamburger on mobile, inline nav on sm+. Closed on
               navigation by the phx:page-loading-stop listener in app.js. --%>
          <input type="checkbox" id="nav-toggle" class="peer hidden" aria-hidden="true" />
          <label
            for="nav-toggle"
            class="sm:hidden brutal-btn px-3 py-2 block-yellow text-ink cursor-pointer"
            aria-label={gettext("Menu")}
          >
            <.icon name="hero-bars-3" class="w-6 h-6" />
          </label>

          <nav class="hidden peer-checked:flex sm:flex basis-full sm:basis-auto flex-col sm:flex-row sm:items-center gap-1 sm:gap-2">
            <.link
              navigate={~p"/focus"}
              class="brutal-btn px-3 py-2 sm:py-1.5 text-xs sm:text-sm block-blue no-underline text-center"
            >
              {gettext("Focus")}
            </.link>
            <.link
              navigate={~p"/progress"}
              class="brutal-btn px-3 py-2 sm:py-1.5 text-xs sm:text-sm block-purple no-underline text-center"
            >
              {gettext("Progress")}
            </.link>
            <.link
              navigate={~p"/settings"}
              class="brutal-btn px-3 py-2 sm:py-1.5 text-xs sm:text-sm block-orange no-underline text-center"
            >
              {gettext("Settings")}
            </.link>
            <.link
              navigate={~p"/about"}
              class="brutal-btn px-3 py-2 sm:py-1.5 text-xs sm:text-sm block-green no-underline text-center"
            >
              {gettext("About")}
            </.link>
          </nav>
        </div>
      </header>

      <main class="flex-1 px-4 sm:px-6 lg:px-8 py-6">
        <%= if assigns[:inner_content] do %>
          {@inner_content}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </main>

      <footer class="border-t-4 border-ink px-4 sm:px-6 lg:px-8 py-3 bg-ink text-paper">
        <div class="flex items-center justify-between text-xs font-mono uppercase tracking-wider">
          <span>DailyOutput</span>
          <span>{gettext("Write every day.")}</span>
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <%!-- Client-rendered toasts (push_event "toast"); re-trigger on every event. --%>
      <div id="toast-tray" class="toast toast-top toast-end z-50" phx-update="ignore"></div>

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
