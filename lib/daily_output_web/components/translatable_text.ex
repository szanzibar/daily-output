defmodule DailyOutputWeb.TranslatableText do
  @moduledoc """
  An AI text with a translate button. The first tap asks for a translation into your native
  language; later taps show or hide it without asking again. It lives only in this
  component, so leaving the page forgets it.

  It takes `id` and `text`, and inherits its font from whatever it sits in.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: DailyOutputWeb.Gettext

  import DailyOutputWeb.CoreComponents, only: [icon: 1]

  alias DailyOutput.Settings
  alias DailyOutput.AI.Translator

  @impl true
  def mount(socket), do: {:ok, assign(socket, translation: nil, open?: false)}

  @impl true
  def handle_event("toggle", _params, %{assigns: %{open?: true}} = socket),
    do: {:noreply, assign(socket, open?: false)}

  def handle_event("toggle", _params, socket) do
    socket = assign(socket, open?: true)

    if socket.assigns.translation in [nil, :failed],
      do: {:noreply, translate(socket)},
      else: {:noreply, socket}
  end

  def handle_event("retry", _params, socket), do: {:noreply, translate(socket)}

  @impl true
  def handle_async(:translate, {:ok, {:ok, translation}}, socket),
    do: {:noreply, assign(socket, translation: translation)}

  def handle_async(:translate, _result, socket),
    do: {:noreply, assign(socket, translation: :failed)}

  defp translate(socket) do
    text = socket.assigns.text

    socket
    |> assign(translation: :loading)
    |> start_async(:translate, fn ->
      Translator.translate(text, Settings.get_config().native_language)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flow-root">
      <%!-- Floated so the text wraps around it. The padding is the tap target, and the
           negative margins tuck it into the corner. --%>
      <button
        id={"#{@id}-button"}
        type="button"
        phx-click="toggle"
        phx-target={@myself}
        aria-label={gettext("Translate")}
        aria-pressed={to_string(@open?)}
        class="float-right -mt-2.5 -mr-3 ml-1 p-2.5 opacity-50 hover:opacity-100 aria-pressed:opacity-100 cursor-pointer"
      >
        <.icon name="hero-language" class="size-5 block" />
      </button>
      {@text}
      <div :if={@open?} class="clear-both mt-2 pt-2 border-t-2 border-dashed border-ink/25">
        <%= case @translation do %>
          <% :loading -> %>
            <span
              id={"#{@id}-loading"}
              class="chat-mini-blocks"
              role="status"
              aria-label={gettext("Translating")}
            >
              <span></span><span></span><span></span>
            </span>
          <% :failed -> %>
            <p id={"#{@id}-error"} class="chat-checking">
              {gettext("Couldn't translate this.")}
              <button
                type="button"
                phx-click="retry"
                phx-target={@myself}
                class="underline font-black cursor-pointer"
              >
                {gettext("Try again")}
              </button>
            </p>
          <% translation -> %>
            <p id={"#{@id}-text"} class="text-[0.9em] font-medium opacity-70">{translation}</p>
        <% end %>
      </div>
    </div>
    """
  end
end
