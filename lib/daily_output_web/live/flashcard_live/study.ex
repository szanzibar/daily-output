defmodule DailyOutputWeb.FlashcardLive.Study do
  @moduledoc """
  Today's card session. Each card in `Today.card_queue/0` comes up once: a miss shows the
  fix and goes back to the scheduler, which brings it back soon. When the queue runs out,
  the session is done and you go back to `/`.
  """
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Flashcards, Settings, Stats, Today}
  alias DailyOutput.AI.LanguageProfile

  # How long the green "correct" lingers before moving on.
  @correct_pause_ms 1100

  # Starting width (in characters) of a fill-in blank. Uniform, so the blank never gives
  # away the answer's length; the ClozeNav hook grows it as you type.
  @blank_min_size 6

  @impl true
  def mount(_params, _session, socket) do
    queue = Today.card_queue()
    config = Settings.get_config()

    socket =
      assign(socket,
        page_title: gettext("Cards"),
        target_language_name: LanguageProfile.resolve(config.target_language).language_name,
        total: length(queue),
        done: 0
      )

    {:ok, next_card(socket, queue)}
  end

  defp next_card(socket, [card | rest]) do
    assign(socket,
      current: card,
      queue: rest,
      phase: :prompt,
      diff: nil,
      case_diffs: [],
      fix_form: nil
    )
  end

  defp next_card(socket, []) do
    Today.finish_cards()
    push_navigate(socket, to: ~p"/")
  end

  defp advance(socket), do: next_card(socket, socket.assigns.queue)

  @impl true
  def handle_event("submit", params, socket) do
    card = socket.assigns.current
    verdict = Flashcards.evaluate(card, answer_from_params(card, params))
    {:ok, reviewed} = Flashcards.review(card, verdict.result, verdict.new_blank_indices)

    # Keep the reviewed copy, so fixing the card acts on its fresh mask.
    socket = assign(socket, current: reviewed, done: socket.assigns.done + 1)

    if verdict.result == :pass do
      Process.send_after(self(), :advance, @correct_pause_ms)

      {:noreply,
       socket
       |> push_event("confetti", %{})
       |> assign(phase: :correct, case_diffs: verdict.case_diffs)}
    else
      {:noreply, assign(socket, phase: :revealed, diff: verdict.diff)}
    end
  end

  def handle_event("continue", _params, socket), do: {:noreply, advance(socket)}

  def handle_event("fix", _params, socket) do
    {:noreply, assign(socket, fix_form: to_form(Flashcards.change_card(socket.assigns.current)))}
  end

  def handle_event("cancel_fix", _params, socket), do: {:noreply, assign(socket, fix_form: nil)}

  def handle_event("save_fix", %{"card" => attrs}, socket) do
    case Flashcards.update_card(socket.assigns.current, attrs) do
      {:ok, card} ->
        socket =
          socket
          |> assign(current: card, fix_form: nil)
          |> put_flash(:info, gettext("Card updated."))

        # A revealed card is already answered; one still on its prompt gets answered as fixed.
        {:noreply, if(socket.assigns.phase == :revealed, do: advance(socket), else: socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, fix_form: to_form(changeset))}
    end
  end

  def handle_event("delete_card", _params, socket) do
    {:ok, _} = Flashcards.delete_card(socket.assigns.current)

    {:noreply,
     socket
     |> assign(done: socket.assigns.done + 1)
     |> put_flash(:info, gettext("Card deleted."))
     |> advance()}
  end

  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    Stats.track(section, seconds)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:advance, socket), do: {:noreply, advance(socket)}

  # A full-answer card sends the typed string; a cloze card an index => text map of blanks.
  defp answer_from_params(%{blank_indices: idx}, params) when not is_list(idx),
    do: params["answer"] || ""

  defp answer_from_params(_card, %{"blank" => blanks}) when is_map(blanks),
    do: Map.new(blanks, fn {k, v} -> {String.to_integer(k), v} end)

  defp answer_from_params(_card, _params), do: %{}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-5">
      <div id="flashcard-time-tracker" phx-hook="TimeTracker" data-section="flashcards" class="hidden">
      </div>

      <div class="flex items-baseline justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">{gettext("Cards")}</h1>
        <span id="card-count" class="text-xs font-mono font-bold text-base-content/60">
          {min(@done + 1, @total)} / {@total}
        </span>
      </div>

      <%= cond do %>
        <% @fix_form -> %>
          <.fix_form form={@fix_form} card={@current} />
        <% @phase == :prompt -> %>
          <.native_prompt card={@current} />
          <%!-- A card you missed before comes back as fill-in-the-blank on just the parts you
               got wrong; a new one you type in full. --%>
          <.cloze_form :if={cloze?(@current)} card={@current} />
          <.full_answer_form
            :if={!cloze?(@current)}
            card={@current}
            target_language_name={@target_language_name}
          />
        <% @phase == :correct -> %>
          <.card_correct card={@current} case_diffs={@case_diffs} />
        <% @phase == :revealed -> %>
          <div class="space-y-4" phx-window-keydown="continue" phx-key="Enter">
            <.native_prompt card={@current} />
            <div id="card-fix-diff" class="border-4 border-ink p-4 sm:p-5">
              <p class="text-xs font-mono uppercase tracking-widest mb-2 text-base-content/60">
                {gettext("Not quite — here's the fix")}
              </p>
              <%!-- The space sits outside the styled word so a strikethrough never bleeds
                   into the gap. --%>
              <p class="font-mono font-bold text-lg leading-relaxed">
                <span :for={seg <- @diff}><span class={seg_class(seg)}>{seg.text}</span>{" "}</span>
              </p>
            </div>
            <button
              type="button"
              phx-click="continue"
              class="brutal-btn w-full px-6 py-3 block-blue text-lg"
            >
              {gettext("Continue")} &rarr;
              <span class="text-xs font-mono opacity-70">({gettext("Enter")})</span>
            </button>
          </div>
      <% end %>
    </div>
    """
  end

  attr :card, :map, required: true

  # What to translate, with the escape hatch for a card the AI got wrong.
  defp native_prompt(assigns) do
    ~H"""
    <div class="border-4 border-ink block-yellow p-5 sm:p-6">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-xs font-mono uppercase tracking-widest mb-2 opacity-60">
            {gettext("Translate")}
          </p>
          <p class="text-2xl sm:text-3xl font-black leading-tight break-words">{@card.native_text}</p>
        </div>
        <button
          id="fix-card"
          type="button"
          phx-click="fix"
          title={gettext("Fix this card")}
          aria-label={gettext("Fix this card")}
          class="opacity-50 hover:opacity-100 p-1 shrink-0"
        >
          <.icon name="hero-pencil-square" class="w-5 h-5" />
        </button>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :target_language_name, :string, required: true

  defp full_answer_form(assigns) do
    ~H"""
    <form phx-submit="submit" class="space-y-3">
      <%!-- `sentences` capitalizes the first letter on mobile, a commonly missed capital. --%>
      <textarea
        id={"answer-#{@card.id}"}
        name="answer"
        rows="3"
        phx-hook="AutoExpand"
        data-persist-key={"flashcard-#{@card.id}"}
        phx-mounted={JS.focus()}
        autocomplete="off"
        autocapitalize="sentences"
        autocorrect="off"
        spellcheck="false"
        placeholder={gettext("Type in %{language}...", language: @target_language_name)}
        class="chat-input w-full text-lg min-h-[5rem]"
      ></textarea>
      <button type="submit" class="brutal-btn w-full px-6 py-3 block-green text-lg">
        {gettext("Check")} &rarr;
      </button>
    </form>
    """
  end

  attr :card, :map, required: true

  defp cloze_form(assigns) do
    assigns =
      assign(assigns,
        segments: Flashcards.cloze_segments(assigns.card),
        min_size: @blank_min_size
      )

    ~H"""
    <%!-- The ClozeNav hook focuses the first blank, jumps to the next on Enter, submits from
         the last, persists keystrokes, and grows each blank as you type. --%>
    <form id={"cloze-#{@card.id}"} phx-submit="submit" phx-hook="ClozeNav" class="space-y-3">
      <div class="border-4 border-ink p-4 sm:p-6 font-mono font-bold text-lg sm:text-xl leading-loose">
        <%= for seg <- @segments do %>
          <%= case seg do %>
            <% {:shown, text} -> %>
              <span>{text}</span>
            <% {:blank, key, _expected} -> %>
              <textarea
                name={"blank[#{key}]"}
                rows="1"
                data-min-size={@min_size}
                data-persist-key={"flashcard-#{@card.id}-blank-#{key}"}
                aria-label={gettext("Fill in the blank")}
                class="cloze-blank inline-block max-w-full resize-none overflow-hidden align-bottom break-words border-b-4 border-ink bg-base-200 px-0 py-0.5 mx-0.5 font-mono font-bold leading-snug focus:block-yellow focus:outline-none"
                autocomplete="off"
                autocapitalize="off"
                autocorrect="off"
                spellcheck="false"
              ></textarea>
          <% end %>
          <span>{" "}</span>
        <% end %>
      </div>
      <button type="submit" class="brutal-btn w-full px-6 py-3 block-green text-lg">
        {gettext("Check")} &rarr;
      </button>
    </form>
    """
  end

  attr :card, :map, required: true
  attr :case_diffs, :list, required: true

  defp card_correct(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="border-4 border-ink block-green p-4 sm:p-5 flex items-center gap-3">
        <span class="text-2xl shrink-0">✓</span>
        <p class="text-xl sm:text-2xl font-black leading-tight">{@card.native_text}</p>
      </div>
      <div class="border-4 border-ink block-green p-4 sm:p-5">
        <p class="font-mono font-bold text-lg leading-relaxed">{@card.target_text}</p>
      </div>
      <%!-- Capitalization is forgiven and counted correct, but flagged so it sticks. --%>
      <div
        :if={@case_diffs != []}
        data-role="case-warning"
        class="border-4 border-ink block-yellow p-3 sm:p-4"
      >
        <p class="text-xs font-mono uppercase tracking-widest mb-1">
          {gettext("Correct — mind the capitalization")}
        </p>
        <p class="font-mono text-sm flex flex-wrap gap-x-3 gap-y-1">
          <span :for={d <- @case_diffs} class="whitespace-nowrap">
            <span class="line-through opacity-60">{d.typed}</span>
            <span aria-hidden="true">→</span>
            <span class="font-black">{d.expected}</span>
          </span>
        </p>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :card, :map, required: true

  defp fix_form(assigns) do
    ~H"""
    <.form for={@form} id="fix-card-form" phx-submit="save_fix" class="space-y-4">
      <div class="border-4 border-ink p-4 sm:p-5 space-y-3">
        <h2 class="text-lg font-black uppercase">{gettext("Fix this card")}</h2>
        <div>
          <label class="text-xs font-mono uppercase tracking-widest">
            {gettext("Prompt (native)")}
          </label>
          <.input
            field={@form[:native_text]}
            type="textarea"
            rows="2"
            phx-hook="AutoExpand"
            data-persist-key={"card-fix-#{@card.id}-native"}
            data-no-enter-submit
            class="w-full textarea border-3 border-ink font-mono"
          />
        </div>
        <div>
          <label class="text-xs font-mono uppercase tracking-widest">
            {gettext("Answer (target)")}
          </label>
          <.input
            field={@form[:target_text]}
            type="textarea"
            rows="2"
            phx-hook="AutoExpand"
            data-persist-key={"card-fix-#{@card.id}-target"}
            data-no-enter-submit
            class="w-full textarea border-3 border-ink font-mono"
          />
        </div>
      </div>
      <div class="flex flex-wrap gap-2">
        <button type="submit" class="brutal-btn px-5 py-2.5 block-green">{gettext("Save")}</button>
        <button type="button" phx-click="cancel_fix" class="brutal-btn px-5 py-2.5 bg-base-200">
          {gettext("Cancel")}
        </button>
        <button
          id="delete-card"
          type="button"
          phx-click="delete_card"
          data-confirm={gettext("Delete this card?")}
          class="brutal-btn px-5 py-2.5 block-red ml-auto"
        >
          {gettext("Delete")}
        </button>
      </div>
    </.form>
    """
  end

  # A card is fill-in-the-blank once it has a non-empty mask of missed words.
  defp cloze?(%{blank_indices: idx}), do: is_list(idx) and idx != []

  # Matches the proofreading pages: struck-out wrong word, green fix, soft red case slip.
  defp seg_class(%{op: :del}), do: "correction-deleted"
  defp seg_class(%{op: :ins}), do: "correction-added"
  defp seg_class(%{op: :case}), do: "correction-case"
  defp seg_class(_), do: nil
end
