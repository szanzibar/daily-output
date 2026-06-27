defmodule DailyOutputWeb.FlashcardLive.Study do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Flashcards, FocusTopics, Settings, Stats}
  alias DailyOutput.AI.LanguageProfile
  alias DailyOutputWeb.Celebration

  # How long the green "correct" celebration lingers before auto-advancing.
  @correct_pause_ms 1100

  @impl true
  def mount(_params, _session, socket) do
    config = Settings.get_config()
    target = Flashcards.daily_target()
    target_name = LanguageProfile.resolve(config.target_language || "de").language_name

    socket =
      socket
      |> assign(
        page_title: gettext("Flashcards"),
        target_language_name: target_name,
        target: target,
        progress: Flashcards.today_progress(),
        input: "",
        diff: nil,
        edit_form: nil,
        more_available: false,
        # If the day is already fully done, don't re-fire the day celebration mid-session.
        day_celebrated: FocusTopics.daily_challenge_status().all_done
      )
      |> load_card(Flashcards.due_today(target))

    {:ok, socket}
  end

  # Pull the next card off the queue, or finish the session.
  defp load_card(socket, [card | rest]) do
    assign(socket, current: card, queue: rest, phase: :prompt, input: "", diff: nil)
  end

  defp load_card(socket, []) do
    assign(socket,
      current: nil,
      queue: [],
      phase: :done,
      input: "",
      diff: nil,
      more_available: Flashcards.due_today(socket.assigns.target) != []
    )
  end

  @impl true
  def handle_event("submit", %{"answer" => answer}, socket) do
    card = socket.assigns.current
    typed = String.trim(answer)
    correct? = typed == String.trim(card.target_text)

    {:ok, updated} = Flashcards.review(card, if(correct?, do: :pass, else: :fail))
    socket = assign(socket, progress: Flashcards.today_progress())

    # If this review just completed the whole day, fire the big celebration once.
    {socket, day_completed?} = maybe_celebrate_day(socket)

    if correct? do
      Process.send_after(self(), :advance_after_correct, @correct_pause_ms)
      # A small confetti pop for the win — unless the big day celebration already fired.
      socket = if day_completed?, do: socket, else: push_event(socket, "confetti", %{})
      {:noreply, assign(socket, phase: :correct)}
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

  def handle_event("study_more", _params, socket) do
    {:noreply, load_card(socket, Flashcards.due_today(socket.assigns.target))}
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

  # Ask the AI for a clearer translation pair when the prompt is too hard to answer.
  def handle_event("ai_improve", _params, socket) do
    card = socket.assigns.current
    pid = self()
    Task.start(fn -> send(pid, {:ai_pair, Flashcards.suggest_pair(card)}) end)
    {:noreply, assign(socket, phase: :improving)}
  end

  # Accumulated active time on this page, pushed by the TimeTracker hook.
  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    Stats.track(section, seconds)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:advance_after_correct, socket) do
    # Guard against a stale tick if the phase changed (e.g. the user navigated away).
    if socket.assigns.phase == :correct,
      do: {:noreply, advance(socket)},
      else: {:noreply, socket}
  end

  # AI suggestion came back: drop into the edit form pre-filled with it for review.
  def handle_info({:ai_pair, {:ok, pair}}, socket) do
    form = to_form(Flashcards.change_card(socket.assigns.current, pair))

    {:noreply,
     socket
     |> assign(phase: :editing, edit_form: form)
     |> put_flash(:info, gettext("AI suggested a clearer translation — review and save."))}
  end

  def handle_info({:ai_pair, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(phase: :revealed)
     |> put_flash(:error, gettext("Could not get an AI suggestion. Please try again."))}
  end

  defp advance(socket), do: load_card(socket, socket.assigns.queue)

  # Fire the shared day-complete / streak celebration the moment a review completes the
  # whole day (no matter which task was last). Returns {socket, fired?}.
  defp maybe_celebrate_day(socket) do
    if not socket.assigns.day_celebrated and FocusTopics.daily_challenge_status().all_done do
      streak = FocusTopics.streak_info()
      socket = Celebration.maybe_push(socket, Celebration.after_completion(true, streak.count))
      {assign(socket, day_celebrated: true), true}
    else
      {socket, false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-5">
      <%!-- Tracks active time on this page; flushed to the server periodically. --%>
      <div id="flashcard-time-tracker" phx-hook="TimeTracker" data-section="flashcards" class="hidden">
      </div>

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
        <% :improving -> %>
          <.card_improving card={@current} />
        <% :editing -> %>
          <.card_edit card={@current} form={@edit_form} />
        <% :done -> %>
          <.session_done progress={@progress} more_available={@more_available} />
      <% end %>
    </div>
    """
  end

  # ── Components ────────────────────────────────────────

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class="border-4 border-ink p-3">
      <div class="flex items-center justify-between mb-2 gap-2">
        <span class="text-xs font-mono uppercase tracking-widest">{gettext("Today")}</span>
        <%= if @progress.complete? do %>
          <span
            data-role="goal-complete"
            class="text-[10px] font-mono font-black uppercase px-2 py-0.5 border-2 border-ink block-green"
          >
            ✓ {gettext("Goal complete")}
          </span>
        <% else %>
          <span class="text-xs font-mono font-bold">{@progress.done} / {@progress.goal}</span>
        <% end %>
      </div>
      <div class="h-4 border-2 border-ink bg-base-200">
        <div
          class="h-full block-green transition-all duration-200"
          style={"width: #{progress_pct(@progress)}%"}
        >
        </div>
      </div>
      <p :if={@progress.complete?} class="text-[10px] font-mono text-base-content/50 mt-1">
        {gettext("Goal reached — keep going for extra practice, or finish anytime.")}
      </p>
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
           sparkles ask the AI for a clearer translation; the pencil edits the card. --%>
      <div class="border-4 border-ink block-yellow p-4 sm:p-5">
        <div class="flex items-start justify-between gap-3">
          <p class="text-xl sm:text-2xl font-black leading-tight text-ink">{@card.native_text}</p>
          <div class="flex items-center gap-1 shrink-0">
            <button
              type="button"
              phx-click="ai_improve"
              title={gettext("Ask AI for a clearer translation")}
              aria-label={gettext("Ask AI for a clearer translation")}
              class="text-ink/50 hover:text-ink p-1"
            >
              <.icon name="hero-sparkles" class="w-5 h-5" />
            </button>
            <button
              type="button"
              phx-click="edit"
              title={gettext("Edit card")}
              aria-label={gettext("Edit card")}
              class="text-ink/50 hover:text-ink p-1"
            >
              <.icon name="hero-pencil-square" class="w-5 h-5" />
            </button>
          </div>
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

  defp card_improving(assigns) do
    ~H"""
    <div class="border-4 border-ink block-yellow p-4 sm:p-5">
      <p class="text-xl sm:text-2xl font-black leading-tight text-ink">{@card.native_text}</p>
    </div>
    <.retro_loader message={gettext("Asking AI for a clearer translation")} />
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
  attr :more_available, :boolean, required: true

  defp session_done(assigns) do
    ~H"""
    <div class="border-4 border-ink block-green p-8 text-center space-y-3">
      <p class="text-5xl">{if @progress.done > 0, do: "🎉", else: "✓"}</p>
      <h2 class="text-2xl font-black uppercase tracking-tighter">
        <%= cond do %>
          <% @progress.complete? and @progress.done > 0 -> %>
            {gettext("Daily goal complete!")}
          <% @progress.done > 0 -> %>
            {gettext("Nice work!")}
          <% true -> %>
            {gettext("All caught up!")}
        <% end %>
      </h2>
      <p class="font-mono text-sm">
        <%= if @progress.done > 0 do %>
          {gettext("You studied %{count} card(s) today.", count: @progress.done)}
        <% else %>
          {gettext("Nothing due right now. Come back tomorrow!")}
        <% end %>
      </p>
      <div class="flex flex-wrap gap-2 justify-center pt-2">
        <button
          :if={@more_available}
          phx-click="study_more"
          class="brutal-btn px-6 py-3 block-blue"
        >
          {gettext("Keep going")} &rarr;
        </button>
        <.link navigate={~p"/"} class="brutal-btn inline-block px-6 py-3 block-yellow no-underline">
          {gettext("Home")} &rarr;
        </.link>
      </div>
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
