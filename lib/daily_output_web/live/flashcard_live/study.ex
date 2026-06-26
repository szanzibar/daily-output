defmodule DailyOutputWeb.FlashcardLive.Study do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Flashcards, FocusTopics, Settings}
  alias DailyOutput.AI.LanguageProfile
  alias DailyOutputWeb.Celebration

  # How long the green "correct" celebration lingers before auto-advancing.
  @correct_pause_ms 1100

  @impl true
  def mount(_params, _session, socket) do
    target = Flashcards.daily_target()
    queue = Flashcards.due_today(target)
    config = Settings.get_config()
    target_name = LanguageProfile.resolve(config.target_language || "de").language_name

    socket =
      socket
      |> assign(
        page_title: gettext("Flashcards"),
        target_language_name: target_name,
        progress: Flashcards.today_progress(),
        input: "",
        diff: nil,
        edit_form: nil
      )
      |> load_card(queue)

    {:ok, socket}
  end

  # Pull the next card off the queue, or finish the session.
  defp load_card(socket, [card | rest]) do
    assign(socket, current: card, queue: rest, phase: :prompt, input: "", diff: nil)
  end

  defp load_card(socket, []) do
    assign(socket, current: nil, queue: [], phase: :done, input: "", diff: nil)
  end

  @impl true
  def handle_event("submit", %{"answer" => answer}, socket) do
    card = socket.assigns.current
    typed = String.trim(answer)
    correct? = typed == String.trim(card.target_text)

    {:ok, updated} = Flashcards.review(card, if(correct?, do: :pass, else: :fail))
    socket = assign(socket, progress: Flashcards.today_progress())

    if correct? do
      # A brief, fun green celebration with a confetti pop, then auto-advance.
      Process.send_after(self(), :advance_after_correct, @correct_pause_ms)
      {:noreply, socket |> assign(phase: :correct) |> push_event("confetti", %{})}
    else
      # Show what didn't match and re-drill this card later in the session.
      {:noreply,
       assign(socket,
         phase: :revealed,
         diff: Flashcards.diff(card.target_text, typed),
         queue: socket.assigns.queue ++ [updated]
       )}
    end
  end

  def handle_event("continue", _params, socket) do
    {:noreply, advance(socket)}
  end

  # Fix a bad card on the spot (e.g. an inexact translation) without leaving the session.
  def handle_event("edit", _params, socket) do
    form = to_form(Flashcards.change_card(socket.assigns.current))
    {:noreply, assign(socket, phase: :editing, edit_form: form)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, phase: :revealed, edit_form: nil)}
  end

  def handle_event("save_edit", %{"card" => attrs}, socket) do
    case Flashcards.update_card(socket.assigns.current, attrs) do
      {:ok, updated} ->
        # Reflect the new text on the copy re-queued for re-drilling this session
        # (keep that copy's scheduling state — only the text changed).
        queue =
          Enum.map(socket.assigns.queue, fn c ->
            if c.id == updated.id,
              do: %{c | target_text: updated.target_text, native_text: updated.native_text},
              else: c
          end)

        socket =
          socket
          |> assign(current: updated, queue: queue, edit_form: nil)
          |> put_flash(:info, gettext("Card updated."))

        {:noreply, advance(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_info(:advance_after_correct, socket) do
    # Guard against a stale tick if the phase changed (e.g. the user navigated away).
    if socket.assigns.phase == :correct,
      do: {:noreply, advance(socket)},
      else: {:noreply, socket}
  end

  defp advance(socket) do
    socket = load_card(socket, socket.assigns.queue)
    if socket.assigns.phase == :done, do: maybe_celebrate(socket), else: socket
  end

  # Finishing cards may complete the whole day — fire the shared celebration if so.
  defp maybe_celebrate(socket) do
    if socket.assigns.progress.complete? do
      challenge = FocusTopics.daily_challenge_status()
      streak = FocusTopics.streak_info()

      Celebration.maybe_push(
        socket,
        Celebration.after_completion(challenge.all_done, streak.count)
      )
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-5">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
          {gettext("Flashcards")}
        </h1>
        <.link
          navigate={~p"/flashcards/manage"}
          class="brutal-btn px-3 py-1.5 text-xs block-purple no-underline"
        >
          {gettext("Manage")}
        </.link>
      </div>

      <.progress_bar progress={@progress} />

      <%= case @phase do %>
        <% :prompt -> %>
          <.card_prompt
            card={@current}
            input={@input}
            target_language_name={@target_language_name}
          />
        <% :correct -> %>
          <.card_correct card={@current} />
        <% :revealed -> %>
          <.card_reveal card={@current} diff={@diff} />
        <% :editing -> %>
          <.card_edit card={@current} form={@edit_form} />
        <% :done -> %>
          <.session_done progress={@progress} />
      <% end %>
    </div>
    """
  end

  # ── Components ────────────────────────────────────────

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class="border-4 border-ink p-3">
      <div class="flex items-center justify-between mb-2">
        <span class="text-xs font-mono uppercase tracking-widest">{gettext("Today")}</span>
        <span class="text-xs font-mono font-bold">
          <%= if @progress.goal > 0 do %>
            {@progress.done} / {@progress.goal}
          <% else %>
            {gettext("Caught up")}
          <% end %>
        </span>
      </div>
      <div class="h-4 border-2 border-ink bg-base-200">
        <div
          class="h-full block-green transition-all duration-200"
          style={"width: #{progress_pct(@progress)}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :input, :string, required: true
  attr :target_language_name, :string, required: true

  defp card_prompt(assigns) do
    ~H"""
    <div class="border-4 border-ink block-yellow p-6 sm:p-8">
      <p class="text-xs font-mono uppercase tracking-widest mb-2 text-ink/60">
        {gettext("Translate")}
      </p>
      <p class="text-2xl sm:text-3xl font-black leading-tight text-ink">{@card.native_text}</p>
    </div>

    <form phx-submit="submit" class="space-y-3">
      <%!-- Auto-expands (min ~3 lines), wraps long answers, submits on Enter, and
           persists what you type per card across refresh/navigation. --%>
      <textarea
        id={"answer-#{@card.id}"}
        name="answer"
        rows="3"
        phx-hook="AutoExpand"
        data-persist-key={"flashcard-#{@card.id}"}
        phx-mounted={JS.focus()}
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
        spellcheck="false"
        placeholder={gettext("Type in %{language}...", language: @target_language_name)}
        class="chat-input w-full text-lg min-h-[5rem]"
      >{@input}</textarea>
      <button type="submit" class="brutal-btn w-full px-6 py-3 block-green text-lg">
        {gettext("Check")} &rarr;
      </button>
    </form>
    """
  end

  attr :card, :map, required: true

  defp card_correct(assigns) do
    ~H"""
    <%!-- A quick green "you got it" before auto-advancing: the prompt and the answer you
         nailed, both in green, with a confetti pop (pushed from the server). --%>
    <div class="space-y-4">
      <div class="border-4 border-ink block-green p-4 sm:p-5 flex items-center gap-3">
        <span class="text-2xl shrink-0">✓</span>
        <p class="text-xl sm:text-2xl font-black leading-tight text-ink">{@card.native_text}</p>
      </div>
      <div class="border-4 border-ink block-green p-4 sm:p-5">
        <p class="font-mono font-bold text-lg leading-relaxed text-ink">{@card.target_text}</p>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :diff, :list, required: true

  defp card_reveal(assigns) do
    ~H"""
    <div class="space-y-4" phx-window-keydown="continue" phx-key="Enter">
      <%!-- Keep the English prompt visible so you can see why your answer was wrong. The
           pencil lets you fix a bad card (e.g. an inexact translation) on the spot. --%>
      <div class="border-4 border-ink block-yellow p-4 sm:p-5">
        <div class="flex items-start justify-between gap-3">
          <p class="text-xl sm:text-2xl font-black leading-tight text-ink">{@card.native_text}</p>
          <button
            type="button"
            phx-click="edit"
            title={gettext("Edit card")}
            aria-label={gettext("Edit card")}
            class="shrink-0 text-ink/50 hover:text-ink p-1"
          >
            <.icon name="hero-pencil-square" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- Your attempt and the fix, unified: wrong words struck out, the correct word
           in green right next to them (same styling as the proofreading pages). --%>
      <div class="border-4 border-ink p-4 sm:p-5">
        <p class="text-xs font-mono uppercase tracking-widest mb-2 text-base-content/60">
          {gettext("Not quite — here's the fix")}
        </p>
        <p class="font-mono font-bold text-lg leading-relaxed">
          <span :for={seg <- @diff} class={seg_class(seg)}>{seg.text <> " "}</span>
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
    """
  end

  attr :card, :map, required: true
  attr :form, :map, required: true

  defp card_edit(assigns) do
    ~H"""
    <.form for={@form} id="flashcard-edit-form" phx-submit="save_edit" class="space-y-4">
      <div class="border-4 border-ink p-4 sm:p-5 space-y-3">
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
      </div>
      <div class="flex gap-2">
        <button type="submit" class="brutal-btn px-5 py-2.5 block-green">{gettext("Save")}</button>
        <button type="button" phx-click="cancel_edit" class="brutal-btn px-5 py-2.5 bg-base-200">
          {gettext("Cancel")}
        </button>
      </div>
    </.form>
    """
  end

  attr :progress, :map, required: true

  defp session_done(assigns) do
    ~H"""
    <div class="border-4 border-ink block-green p-8 text-center space-y-3">
      <p class="text-5xl">{if @progress.done > 0, do: "🎉", else: "✓"}</p>
      <h2 class="text-2xl font-black uppercase tracking-tighter">
        {if @progress.done > 0, do: gettext("All done for today!"), else: gettext("All caught up!")}
      </h2>
      <p class="font-mono text-sm">
        <%= if @progress.done > 0 do %>
          {gettext("You studied %{count} card(s) today.", count: @progress.done)}
        <% else %>
          {gettext("Nothing due right now. Come back tomorrow!")}
        <% end %>
      </p>
      <.link navigate={~p"/"} class="brutal-btn inline-block px-6 py-3 block-yellow no-underline mt-2">
        {gettext("Home")} &rarr;
      </.link>
    </div>
    """
  end

  defp progress_pct(%{done: done, goal: goal}) when goal > 0 do
    min(100, round(done * 100 / goal))
  end

  defp progress_pct(_), do: 100

  # Unified diff styling, matching the proofreading pages: struck-out wrong word,
  # green corrected word, plain for unchanged words.
  defp seg_class(%{op: :del}), do: "correction-deleted"
  defp seg_class(%{op: :ins}), do: "correction-added"
  defp seg_class(_), do: nil
end
