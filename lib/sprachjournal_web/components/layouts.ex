defmodule SprachjournalWeb.Layouts do
  @moduledoc """
  Layout components for Sprachjournal.
  """
  use SprachjournalWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="border-b-4 border-ink bg-paper">
        <div class="px-4 sm:px-6 lg:px-8 py-3 flex items-center justify-between">
          <a href="/" class="flex items-baseline gap-2 no-underline">
            <span class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
              Sprach<span class="text-bold-red">journal</span>
            </span>
          </a>
          <nav class="flex items-center gap-1 sm:gap-2">
            <.link
              navigate={~p"/"}
              class="brutal-btn px-3 py-1.5 sm:px-4 sm:py-2 text-xs sm:text-sm block-yellow no-underline"
            >
              Schreiben
            </.link>
            <.link
              navigate={~p"/settings"}
              class="brutal-btn px-3 py-1.5 sm:px-4 sm:py-2 text-xs sm:text-sm bg-base-200 no-underline"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </.link>
          </nav>
        </div>
      </header>

      <main class="flex-1 px-4 sm:px-6 lg:px-8 py-6">
        {render_slot(@inner_block)}
      </main>

      <footer class="border-t-4 border-ink px-4 sm:px-6 lg:px-8 py-3 bg-ink text-paper">
        <div class="flex items-center justify-between text-xs font-mono uppercase tracking-wider">
          <span>Sprachjournal</span>
          <span>Schreib jeden Tag.</span>
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
