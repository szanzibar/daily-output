defmodule DailyOutput.Flashcards do
  @moduledoc """
  Spaced-repetition flashcards built from the learner's corrected mistakes.

  This context is the **entire public interface** to the flashcard subsystem — the rest
  of the app only ever calls functions here. The scheduling math (`Scheduler`), the AI
  card generation (`Generator`), the diff (`Diff`) and the marker parsing (`Markers`)
  are private internals.

  Everything is keyed off the current `target_language`/`native_language` from settings,
  so the feature is language-agnostic.
  """

  import Ecto.Query

  alias DailyOutput.{Clock, Repo, Settings}
  alias DailyOutput.Conversations.Message

  alias DailyOutput.Flashcards.{
    Card,
    Cloze,
    CompletedDay,
    Diff,
    Generator,
    Markers,
    Review,
    Scheduler
  }

  @default_daily_target 15

  # ── Settings ─────────────────────────────────────────

  @doc "Configured number of cards that make a full flashcard day."
  def daily_target do
    case Settings.get_config().flashcards_per_day do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_daily_target
    end
  end

  # ── Ingest (turn a correction into cards) ────────────

  @doc """
  Generates flashcards from one correction and stores them (deduped).

  Best-effort and synchronous — callers in the request path should wrap this in a
  `Task.start/1` so AI latency never blocks the entry/conversation flow. Returns
  `{:ok, count}` (0 when there was nothing substantive to drill) or `{:error, reason}`.

  Capitalization-only corrections are filtered out *before* any AI call, so a message
  whose only fix was a missed capital never spends a request.
  """
  def ingest_correction(source_type, source_id, feedback, opts \\ [])

  def ingest_correction(_source_type, _source_id, nil, _opts), do: {:ok, 0}

  def ingest_correction(source_type, source_id, feedback, opts) do
    annotated = feedback["annotated_text"] || ""
    mistakes = annotated |> Markers.parse() |> Markers.substantive()

    if mistakes == [] do
      {:ok, 0}
    else
      config = opts[:config] || Settings.get_config()
      target = config.target_language || "de"
      native = config.native_language || "en"
      level = config.language_level || "B2"
      corrected = Markers.corrected_text(annotated)

      case Generator.generate(corrected, mistakes,
             target_language: target,
             native_language: native,
             language_level: level
           ) do
        {:ok, cards} ->
          inserted =
            cards
            |> Enum.map(&insert_card(&1, target, to_string(source_type), source_id))
            |> Enum.count(&match?({:ok, %Card{}}, &1))

          {:ok, inserted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Generates flashcards for a whole conversation in a **single** AI call.

  Conversations are corrected per message, but turning each message into cards as it lands
  means one AI request per corrected turn. This combines every user message's substantive
  corrections into one `Generator.generate/3` call at conversation completion — one request
  instead of N. `messages` is the transcript (anything with `.role` and `.feedback`); cards
  are stored under source_type "conversation".

  Same contract as `ingest_correction/4`: capitalization-only fixes are filtered before any
  AI call, returns `{:ok, count}` (0 when nothing substantive) or `{:error, reason}`, and is
  best-effort — wrap it in a `Task` so AI latency never blocks the completion flow.
  """
  def ingest_conversation(conversation_id, messages, opts \\ []) do
    # Only card user messages not already carded by an earlier completion. A conversation is
    # "continued" by copying its messages into a fresh conversation (see
    # `Conversations.copy_message/2`), so the flashcards_at watermark travels with them —
    # re-completing then cards only the genuinely new turns instead of duplicating old ones.
    # ponytail: reads the watermark off the in-memory structs; the continue flow always
    # re-mounts with fresh rows, so they're current.
    new_messages =
      messages
      |> Enum.filter(&(&1.role == "user" and is_map(Map.get(&1, :feedback))))
      |> Enum.reject(&Map.get(&1, :flashcards_at))

    corrections =
      Enum.flat_map(new_messages, fn msg ->
        annotated = msg.feedback["annotated_text"] || ""

        case annotated |> Markers.parse() |> Markers.substantive() do
          [] -> []
          mistakes -> [{Markers.corrected_text(annotated), mistakes}]
        end
      end)

    if corrections == [] do
      {:ok, 0}
    else
      config = opts[:config] || Settings.get_config()
      target = config.target_language || "de"
      native = config.native_language || "en"
      level = config.language_level || "B2"

      corrected = corrections |> Enum.map_join("\n", &elem(&1, 0))
      mistakes = Enum.flat_map(corrections, &elem(&1, 1))

      case Generator.generate(corrected, mistakes,
             target_language: target,
             native_language: native,
             language_level: level
           ) do
        {:ok, []} ->
          # The model produced no cards this round (empty/transient response). Do NOT stamp —
          # leave the messages so a later completion retries them, instead of silently losing
          # the flashcards forever.
          {:ok, 0}

        {:ok, cards} ->
          inserted =
            cards
            |> Enum.map(&insert_card(&1, target, "conversation", conversation_id))
            |> Enum.count(&match?({:ok, %Card{}}, &1))

          mark_carded(new_messages)
          {:ok, inserted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Stamp the messages we just turned into cards so a later completion never re-cards them.
  defp mark_carded(messages) do
    ids = messages |> Enum.map(&Map.get(&1, :id)) |> Enum.reject(&is_nil/1)

    if ids != [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.update_all(from(m in Message, where: m.id in ^ids), set: [flashcards_at: now])
    end
  end

  defp insert_card(
         %{"target_text" => target_text, "native_text" => native_text},
         language,
         source_type,
         source_id
       ) do
    if card_exists?(target_text, language) do
      {:ok, :duplicate}
    else
      %Card{}
      |> Card.changeset(%{
        target_text: target_text,
        native_text: native_text,
        language: language,
        source_type: source_type,
        source_id: source_id,
        state: "new"
      })
      |> Repo.insert()
    end
  end

  defp card_exists?(target_text, language) do
    Repo.exists?(
      from(c in Card,
        where: c.target_text == ^target_text and c.language == ^language and is_nil(c.deleted_at)
      )
    )
  end

  # ── Study session ────────────────────────────────────

  @doc """
  The distinct cards to study today for the current target language: all due reviews
  first (oldest due first), then new cards to fill up to `target`. Capped at `target`.
  """
  def due_today(target \\ nil) do
    target = target || daily_target()
    language = Settings.get_config().target_language || "de"
    now = DateTime.utc_now()

    due =
      Repo.all(
        from(c in Card,
          where:
            is_nil(c.deleted_at) and c.language == ^language and
              c.state in ["review", "learning", "relearning"] and
              not is_nil(c.due_at) and c.due_at <= ^now,
          order_by: [asc: c.due_at],
          limit: ^target
        )
      )

    remaining = target - length(due)

    new_cards =
      if remaining > 0 do
        Repo.all(
          from(c in Card,
            where: is_nil(c.deleted_at) and c.language == ^language and c.state == "new",
            order_by: [asc: c.inserted_at],
            limit: ^remaining
          )
        )
      else
        []
      end

    due ++ new_cards
  end

  @doc """
  Evaluates a study `answer` for `card` (case-insensitive, with progressive
  fill-in-the-blank). `answer` is the typed string for a full-answer card, or a
  `%{index => typed}` map of filled blanks for a cloze card. See `Cloze.evaluate/3`.
  """
  def evaluate(%Card{} = card, answer) do
    Cloze.evaluate(card.target_text, card.blank_indices, answer)
  end

  @doc "Render segments (shown words / fill-in blanks) for a cloze card. See `Cloze.segments/2`."
  def cloze_segments(%Card{} = card), do: Cloze.segments(card.target_text, card.blank_indices)

  @doc """
  Records a `:pass`/`:fail` for `card`: logs the review and persists the rescheduled
  card (new `due_at`/interval/ease/state from `Scheduler`). Returns `{:ok, updated_card}`.

  `blank_indices` updates the fill-in-the-blank mask in the same transaction (pass the
  verdict's `new_blank_indices`); the default leaves it untouched.
  """
  def review(%Card{} = card, result, blank_indices \\ :keep) when result in [:pass, :fail] do
    fields = Scheduler.review(card, result)

    fields =
      if blank_indices == :keep, do: fields, else: Map.put(fields, :blank_indices, blank_indices)

    outcome =
      Repo.transaction(fn ->
        {:ok, updated} = card |> Card.schedule_changeset(fields) |> Repo.update()

        {:ok, _} =
          %Review{}
          |> Review.changeset(%{card_id: card.id, result: result == :pass})
          |> Repo.insert()

        updated
      end)

    # Once this review tips today over the quota, record the day as a settled fact so a later
    # change to the daily target can never revoke it. Idempotent (the day is unique).
    if today_progress().complete?, do: mark_completed(Clock.today())

    outcome
  end

  # Records `date` as a completed flashcard day. Idempotent — re-recording a day is a no-op.
  defp mark_completed(date) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(CompletedDay, [%{day: date, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: :day
    )
  end

  @doc "Unified word-level diff of the typed answer against the expected one (for the reveal)."
  defdelegate diff(expected, actual), to: Diff, as: :unified

  @doc """
  Asks the AI for a clearer translation pair for `card` (when the prompt is too ambiguous
  to answer). Returns `{:ok, %{"target_text", "native_text"}}` or `{:error, reason}` — it
  does not persist anything; the caller decides whether to apply it.
  """
  def suggest_pair(%Card{} = card) do
    config = Settings.get_config()

    Generator.improve(card,
      target_language: config.target_language || "de",
      native_language: config.native_language || "en",
      language_level: config.language_level || "B2"
    )
  end

  # ── Progress / streak interface ──────────────────────

  @doc """
  Today's flashcard progress: `%{done, goal, target, complete?}`.

  `done` counts *distinct* cards reviewed today (re-drilling a missed card doesn't
  inflate it). `goal` is the realistic target given how many cards are actually
  available (so a small deck can still be "finished"). `complete?` means the day's
  flashcard task is done.
  """
  def today_progress do
    target = daily_target()
    done = distinct_reviewed_on(Clock.today())
    remaining = length(due_today(target))
    goal = max(done, min(target, done + remaining))

    %{
      done: done,
      goal: goal,
      target: target,
      complete?: done >= goal
    }
  end

  @doc """
  The set of logical dates whose flashcard quota was met — consumed by the streak engine.

  Past days are read from the recorded completions (a settled fact, see `CompletedDay`), so
  a later change to the daily target can't revoke a day that was already earned. Today is
  still evaluated live via the availability-aware `today_progress/0` (and recorded the moment
  it's met), so a caught-up day counts immediately.
  """
  def completed_dates do
    today = Clock.today()
    recorded = Repo.all(from(d in CompletedDay, select: d.day)) |> MapSet.new()

    if today_progress().complete? and any_reviewed_today?(),
      do: MapSet.put(recorded, today),
      else: recorded
  end

  defp any_reviewed_today?, do: distinct_reviewed_on(Clock.today()) > 0

  defp distinct_reviewed_on(date) do
    {start, stop} = Clock.day_range(date)

    Repo.one(
      from(r in Review,
        where: r.inserted_at >= ^start and r.inserted_at < ^stop and not is_nil(r.card_id),
        select: count(r.card_id, :distinct)
      )
    ) || 0
  end

  # ── Management (edit / delete) ───────────────────────

  @doc "All non-deleted cards, newest first."
  def list_cards do
    Repo.all(from(c in Card, where: is_nil(c.deleted_at), order_by: [desc: c.inserted_at]))
  end

  def get_card!(id) do
    Card |> where([c], is_nil(c.deleted_at)) |> Repo.get!(id)
  end

  @doc "Edits a card's two text sides."
  def update_card(%Card{} = card, attrs) do
    card |> Card.edit_changeset(attrs) |> Repo.update()
  end

  def change_card(%Card{} = card, attrs \\ %{}), do: Card.edit_changeset(card, attrs)

  @doc "Soft-deletes a card (it leaves the study rotation)."
  def delete_card(%Card{} = card) do
    card
    |> Card.changeset(%{deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc "Total non-deleted card count (for the management page header)."
  def count_cards do
    Repo.one(from(c in Card, where: is_nil(c.deleted_at), select: count(c.id))) || 0
  end
end
