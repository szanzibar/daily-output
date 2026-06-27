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
  alias DailyOutput.Flashcards.{Card, Diff, Generator, Markers, Review, Scheduler}

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
    markers = Markers.parse(annotated)
    substantive = Markers.substantive(markers)

    if substantive == [] do
      {:ok, 0}
    else
      config = opts[:config] || Settings.get_config()
      target = config.target_language || "de"
      native = config.native_language || "en"
      level = config.language_level || "B2"
      corrected = Markers.corrected_text(annotated)
      mistakes = build_mistakes(substantive, feedback["annotations"])

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

  # Join the substantive markers with their annotation (by id) for richer AI context.
  defp build_mistakes(markers, annotations) do
    annotations = if is_list(annotations), do: annotations, else: []

    ann_by_id =
      annotations
      |> Enum.filter(&is_map/1)
      |> Map.new(fn a -> {to_string(a["id"]), a} end)

    Enum.map(markers, fn m ->
      ann = Map.get(ann_by_id, to_string(m.id), %{})

      %{
        original: m.original,
        corrected: m.corrected,
        category: ann["category"] || "other",
        explanation: ann["explanation"] || ""
      }
    end)
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
  Records a `:pass`/`:fail` for `card`: logs the review and persists the rescheduled
  card (new `due_at`/interval/ease/state from `Scheduler`). Returns `{:ok, updated_card}`.
  """
  def review(%Card{} = card, result) when result in [:pass, :fail] do
    fields = Scheduler.review(card, result)

    Repo.transaction(fn ->
      {:ok, updated} = card |> Card.schedule_changeset(fields) |> Repo.update()

      {:ok, _} =
        %Review{}
        |> Review.changeset(%{card_id: card.id, result: result == :pass})
        |> Repo.insert()

      updated
    end)
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

  Past days count when at least `target` distinct cards were reviewed; today uses the
  availability-aware `today_progress/0` so a caught-up day still counts.
  """
  def completed_dates do
    target = daily_target()
    today = Clock.today()

    past =
      reviews_by_logical_date()
      |> Enum.filter(fn {date, count} -> date != today and count >= target end)
      |> Enum.map(fn {date, _} -> date end)
      |> MapSet.new()

    if today_progress().complete? and any_reviewed_today?(),
      do: MapSet.put(past, today),
      else: past
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

  # date => distinct card count, grouped by the app's logical (4am-boundary) date.
  defp reviews_by_logical_date do
    Repo.all(from(r in Review, where: not is_nil(r.card_id), select: {r.card_id, r.inserted_at}))
    |> Enum.group_by(fn {_card_id, at} -> Clock.to_logical_date(at) end, fn {card_id, _} ->
      card_id
    end)
    |> Enum.map(fn {date, card_ids} -> {date, card_ids |> Enum.uniq() |> length()} end)
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
