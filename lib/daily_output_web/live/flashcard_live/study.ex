defmodule DailyOutputWeb.FlashcardLive.Study do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Flashcards, FocusTopics, Settings, Stats}
  alias DailyOutput.AI.LanguageProfile
  alias DailyOutputWeb.Celebration

  # How long the green "correct" celebration lingers before auto-advancing.
  @correct_pause_ms 1100

  # Starting width (in characters) of a fill-in blank. Deliberately uniform so the blank
  # never telegraphs the answer's length; the ClozeNav hook grows it as you type.
  @blank_min_size 6

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
        case_diffs: [],
        edit_form: nil,
        more_available: false,
        # Cards already answered this session, oldest first — the "Previous" history. While
        # `review_index` is an index into it, we're looking back instead of studying live.
        history: [],
        review_index: nil,
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
  def handle_event("submit", params, socket) do
    card = socket.assigns.current
    verdict = Flashcards.evaluate(card, answer_from_params(card, params))

    {:ok, updated} = Flashcards.review(card, verdict.result, verdict.new_blank_indices)

    socket =
      socket
      |> assign(progress: Flashcards.today_progress())
      |> record_history(card, verdict)

    # If this review just completed the whole day, fire the big celebration once.
    {socket, day_completed?} = maybe_celebrate_day(socket)

    if verdict.result == :pass do
      Process.send_after(self(), :advance_after_correct, @correct_pause_ms)
      # A small confetti pop for the win — unless the big day celebration already fired.
      socket = if day_completed?, do: socket, else: push_event(socket, "confetti", %{})
      {:noreply, assign(socket, phase: :correct, case_diffs: verdict.case_diffs)}
    else
      # Show what didn't match and re-drill this card (now eased) later in the session.
      # Track the reviewed copy as `current` so an inline edit acts on its fresh mask.
      {:noreply,
       assign(socket,
         current: updated,
         phase: :revealed,
         diff: verdict.diff,
         queue: socket.assigns.queue ++ [updated]
       )}
    end
  end

  def handle_event("continue", _params, socket) do
    {:noreply, advance(socket)}
  end

  # Look back through this session's already-answered cards. Left/"Previous" steps back,
  # Right/"Next" steps forward, and stepping past the newest returns to the live card.
  def handle_event("prev", _params, socket), do: {:noreply, review_step(socket, :prev)}
  def handle_event("next", _params, socket), do: {:noreply, review_step(socket, :next)}
  def handle_event("resume", _params, socket), do: {:noreply, assign(socket, review_index: nil)}

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
              do: %{
                c
                | target_text: updated.target_text,
                  native_text: updated.native_text,
                  blank_indices: updated.blank_indices
              },
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

  # Append the card just answered to the session history (what "Previous" walks back
  # through), keeping the corrections diff / case slips so the review can replay them.
  defp record_history(socket, card, verdict) do
    entry = %{
      card: card,
      result: verdict.result,
      diff: verdict.diff,
      case_diffs: verdict.case_diffs
    }

    assign(socket, history: socket.assigns.history ++ [entry])
  end

  # Move the review pointer. From the live card, :prev jumps to the newest answered card;
  # :next from the newest answered card returns to live (review_index = nil).
  defp review_step(socket, :prev) do
    cond do
      socket.assigns.history == [] ->
        socket

      is_nil(socket.assigns.review_index) ->
        assign(socket, review_index: length(socket.assigns.history) - 1)

      true ->
        assign(socket, review_index: max(0, socket.assigns.review_index - 1))
    end
  end

  defp review_step(socket, :next) do
    case socket.assigns.review_index do
      nil ->
        socket

      idx ->
        if idx + 1 >= length(socket.assigns.history),
          do: assign(socket, review_index: nil),
          else: assign(socket, review_index: idx + 1)
    end
  end

  # The typed answer in the shape `Flashcards.evaluate/2` expects: a raw string for a
  # full-answer card, or an index→text map of the filled blanks for a cloze card.
  defp answer_from_params(%{blank_indices: idx}, params) when not is_list(idx),
    do: params["answer"] || ""

  defp answer_from_params(_card, %{"blank" => blanks}) when is_map(blanks),
    do: Map.new(blanks, fn {k, v} -> {String.to_integer(k), v} end)

  defp answer_from_params(_card, _params), do: %{}

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
      <%!-- ←/→ step through previously-answered cards (ignored while typing in a field). --%>
      <div id="flashcard-keynav" phx-hook="KeyNav" class="hidden"></div>

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

      <%= if @review_index do %>
        <.card_review
          entry={Enum.at(@history, @review_index)}
          position={@review_index + 1}
          total={length(@history)}
        />
      <% else %>
        <%= case @phase do %>
          <% :prompt -> %>
            <.card_prompt
              card={@current}
              input={@input}
              target_language_name={@target_language_name}
            />
          <% :correct -> %>
            <.card_correct card={@current} case_diffs={@case_diffs} />
          <% :revealed -> %>
            <.card_reveal card={@current} diff={@diff} />
          <% :improving -> %>
            <.card_improving card={@current} />
          <% :editing -> %>
            <.card_edit card={@current} form={@edit_form} />
          <% :done -> %>
            <.session_done progress={@progress} more_available={@more_available} />
        <% end %>

        <%!-- Peek back at cards already answered this session. --%>
        <div :if={@history != [] and @phase in [:prompt, :correct, :revealed, :done]} class="flex">
          <button type="button" phx-click="prev" class="brutal-btn px-3 py-1.5 text-xs bg-base-200">
            &larr; {gettext("Previous")}
          </button>
        </div>
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
      <p class="text-xs font-mono uppercase tracking-widest mb-2 opacity-60">
        {gettext("Translate")}
      </p>
      <p class="text-2xl sm:text-3xl font-black leading-tight">{@card.native_text}</p>
    </div>

    <%!-- Cards you've missed before come back as fill-in-the-blank on just the parts you
         got wrong; a brand-new card you still type in full. --%>
    <%= if cloze?(@card) do %>
      <.cloze_form card={@card} />
    <% else %>
      <.full_answer_form card={@card} input={@input} target_language_name={@target_language_name} />
    <% end %>
    """
  end

  attr :card, :map, required: true
  attr :input, :string, required: true
  attr :target_language_name, :string, required: true

  defp full_answer_form(assigns) do
    ~H"""
    <form phx-submit="submit" class="space-y-3">
      <%!-- Auto-expands (min ~3 lines), wraps long answers, submits on Enter, and
           persists what you type per card across refresh/navigation. `sentences`
           auto-capitalizes the first letter on mobile (a common missed-capital). --%>
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
      >{@input}</textarea>
      <button type="submit" class="brutal-btn w-full px-6 py-3 block-green text-lg">
        {gettext("Check")} &rarr;
      </button>
    </form>
    """
  end

  attr :card, :map, required: true

  defp cloze_form(assigns) do
    assigns =
      assigns
      |> assign(:segments, Flashcards.cloze_segments(assigns.card))
      |> assign(:min_size, @blank_min_size)

    ~H"""
    <%!-- The answer with the parts you've already nailed shown, and an inline input for
         each part you still miss. The ClozeNav hook focuses the first blank, jumps to the
         next on Enter, submits from the last, persists keystrokes, and grows each blank as
         you type — never revealing the answer's length up front. --%>
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

  attr :diff, :list, required: true
  attr :label, :string, required: true

  # The unified green/red corrections block: wrong words struck out, the correct word in
  # green next to them. Shared by the live reveal and the history review.
  defp corrections_block(assigns) do
    ~H"""
    <div class="border-4 border-ink p-4 sm:p-5">
      <p class="text-xs font-mono uppercase tracking-widest mb-2 text-base-content/60">{@label}</p>
      <%!-- The space sits outside the styled word so a strikethrough/highlight never
           bleeds through the gap between words. --%>
      <p class="font-mono font-bold text-lg leading-relaxed">
        <span :for={seg <- @diff}><span class={seg_class(seg)}>{seg.text}</span>{" "}</span>
      </p>
    </div>
    """
  end

  attr :case_diffs, :list, required: true

  # Soft capitalization warning: the words typed with the wrong case (still counted correct).
  defp case_warning(assigns) do
    ~H"""
    <%!-- Capitalization is forgiven (German nouns are easy to forget) — counted correct,
         but flagged so it sticks. --%>
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
    """
  end

  attr :card, :map, required: true
  attr :case_diffs, :list, default: []

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
      <.case_warning case_diffs={@case_diffs} />
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
          <p class="text-xl sm:text-2xl font-black leading-tight">{@card.native_text}</p>
          <div class="flex items-center gap-1 shrink-0">
            <button
              type="button"
              phx-click="ai_improve"
              title={gettext("Ask AI for a clearer translation")}
              aria-label={gettext("Ask AI for a clearer translation")}
              class="opacity-50 hover:opacity-100 p-1"
            >
              <.icon name="hero-sparkles" class="w-5 h-5" />
            </button>
            <button
              type="button"
              phx-click="edit"
              title={gettext("Edit card")}
              aria-label={gettext("Edit card")}
              class="opacity-50 hover:opacity-100 p-1"
            >
              <.icon name="hero-pencil-square" class="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>

      <%!-- Your attempt and the fix, unified: wrong words struck out, the correct word
           in green right next to them (same styling as the proofreading pages). --%>
      <.corrections_block diff={@diff} label={gettext("Not quite — here's the fix")} />

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
      <p class="text-xl sm:text-2xl font-black leading-tight">{@card.native_text}</p>
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

  attr :entry, :map, required: true
  attr :position, :integer, required: true
  attr :total, :integer, required: true

  defp card_review(assigns) do
    ~H"""
    <%!-- Read-only look back at a card already answered this session: the prompt, the
         correct answer, and how it went. ←/→ or the buttons walk through the history. --%>
    <div class="space-y-4" data-role="card-review">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-mono uppercase tracking-widest opacity-60">
          {gettext("Reviewing")} · {@position} / {@total}
        </span>
        <%= if @entry.result == :pass do %>
          <span
            data-role="review-result"
            data-result="pass"
            class="text-[10px] font-mono font-black uppercase px-2 py-0.5 border-2 border-ink block-green"
          >
            ✓ {gettext("Correct")}
          </span>
        <% else %>
          <span
            data-role="review-result"
            data-result="fail"
            class="text-[10px] font-mono font-black uppercase px-2 py-0.5 border-2 border-ink block-red"
          >
            ✗ {gettext("Missed")}
          </span>
        <% end %>
      </div>

      <div class="border-4 border-ink block-yellow p-4 sm:p-5">
        <p class="text-xs font-mono uppercase tracking-widest mb-2 opacity-60">
          {gettext("Translate")}
        </p>
        <p class="text-xl sm:text-2xl font-black leading-tight">{@entry.card.native_text}</p>
      </div>

      <%!-- A missed card replays the same green/red corrections from the reveal; a card you
           nailed just shows the answer (plus any capitalization nudge). --%>
      <%= if @entry.diff do %>
        <.corrections_block diff={@entry.diff} label={gettext("Corrections")} />
      <% else %>
        <div class="border-4 border-ink p-4 sm:p-5">
          <p class="text-xs font-mono uppercase tracking-widest mb-2 text-base-content/60">
            {gettext("Answer")}
          </p>
          <p class="font-mono font-bold text-lg leading-relaxed">{@entry.card.target_text}</p>
        </div>
        <.case_warning case_diffs={@entry.case_diffs} />
      <% end %>

      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="prev"
          disabled={@position <= 1}
          class="brutal-btn px-4 py-2.5 bg-base-200 disabled:opacity-40 disabled:cursor-not-allowed"
        >
          &larr; {gettext("Previous")}
        </button>
        <button type="button" phx-click="next" class="brutal-btn px-4 py-2.5 block-blue">
          <%= if @position >= @total do %>
            {gettext("Back to studying")} &rarr;
          <% else %>
            {gettext("Next")} &rarr;
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  defp progress_pct(%{done: done, goal: goal}) when goal > 0 do
    min(100, round(done * 100 / goal))
  end

  defp progress_pct(_), do: 100

  # A card is in fill-in-the-blank mode once it has a (non-empty) mask of missed words.
  defp cloze?(%{blank_indices: idx}), do: is_list(idx) and idx != []

  # Unified diff styling, matching the proofreading pages: struck-out wrong word, green
  # corrected word, plain for unchanged words, and a soft red for a capitalization slip.
  defp seg_class(%{op: :del}), do: "correction-deleted"
  defp seg_class(%{op: :ins}), do: "correction-added"
  defp seg_class(%{op: :case}), do: "correction-case"
  defp seg_class(_), do: nil
end
