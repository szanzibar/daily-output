defmodule DailyOutputWeb.FlashcardLive.Manage do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Flashcards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Manage Flashcards"), editing_id: nil, form: nil)
     |> load_cards()}
  end

  defp load_cards(socket), do: assign(socket, cards: Flashcards.list_cards())

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    card = Flashcards.get_card!(id)
    {:noreply, assign(socket, editing_id: card.id, form: to_form(Flashcards.change_card(card)))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, form: nil)}
  end

  def handle_event("save", %{"card" => attrs}, socket) do
    card = Flashcards.get_card!(socket.assigns.editing_id)

    case Flashcards.update_card(card, attrs) do
      {:ok, _card} ->
        {:noreply,
         socket
         |> assign(editing_id: nil, form: nil)
         |> load_cards()
         |> put_flash(:info, gettext("Card updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Flashcards.get_card!() |> Flashcards.delete_card()

    {:noreply,
     socket
     |> assign(editing_id: nil, form: nil)
     |> load_cards()
     |> put_flash(:info, gettext("Card deleted."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto space-y-5">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
          {gettext("Manage Flashcards")}
        </h1>
        <.link
          navigate={~p"/flashcards"}
          class="brutal-btn px-3 py-1.5 text-xs block-green no-underline"
        >
          {gettext("Study")} &rarr;
        </.link>
      </div>

      <p class="text-sm font-mono text-base-content/60">
        {ngettext("%{count} card", "%{count} cards", length(@cards), count: length(@cards))}
      </p>

      <div :if={@cards == []} class="border-4 border-ink p-8 text-center">
        <p class="font-mono text-base-content/50">
          {gettext("No flashcards yet. They are created from your corrections.")}
        </p>
      </div>

      <div class="space-y-3">
        <div :for={card <- @cards} class="border-4 border-ink">
          <%= if @editing_id == card.id do %>
            <.form for={@form} phx-submit="save" class="p-4 space-y-3">
              <div>
                <label class="text-xs font-mono uppercase tracking-widest">
                  {gettext("Answer (target)")}
                </label>
                <.input
                  field={@form[:target_text]}
                  type="textarea"
                  rows="2"
                  class="w-full textarea border-3 border-ink font-mono"
                />
              </div>
              <div>
                <label class="text-xs font-mono uppercase tracking-widest">
                  {gettext("Prompt (native)")}
                </label>
                <.input
                  field={@form[:native_text]}
                  type="textarea"
                  rows="2"
                  class="w-full textarea border-3 border-ink font-mono"
                />
              </div>
              <div class="flex gap-2">
                <button type="submit" class="brutal-btn px-4 py-2 block-green text-sm">
                  {gettext("Save")}
                </button>
                <button
                  type="button"
                  phx-click="cancel"
                  class="brutal-btn px-4 py-2 bg-base-200 text-sm"
                >
                  {gettext("Cancel")}
                </button>
              </div>
            </.form>
          <% else %>
            <div class="p-4 flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <p class="font-mono font-bold break-words">{card.target_text}</p>
                <p class="font-mono text-sm text-base-content/60 break-words">{card.native_text}</p>
                <span class="inline-block mt-2 text-[0.65rem] font-mono uppercase tracking-widest px-2 py-0.5 border-2 border-ink bg-base-200">
                  {card.state}
                </span>
              </div>
              <div class="flex gap-2 shrink-0">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-id={card.id}
                  class="brutal-btn px-3 py-1.5 block-blue text-xs"
                >
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={card.id}
                  data-confirm={gettext("Delete this card?")}
                  class="brutal-btn px-3 py-1.5 block-red text-xs"
                >
                  {gettext("Delete")}
                </button>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
