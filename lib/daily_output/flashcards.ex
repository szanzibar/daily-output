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

  alias DailyOutput.{Repo, Settings}

  alias DailyOutput.Flashcards.{
    Card,
    Cloze,
    CompletedDay,
    Generator,
    Markers,
    Review,
    Scheduler
  }

  # ── Ingest (turn corrections into cards) ─────────────

  @doc """
  Builds cards from a completed activity's corrections in one AI call: the journal's own
  feedback plus each message's. Only the sentences with a mistake go in, so no card drills
  something you already got right. Cards point back at the activity.

  Capitalization-only fixes are dropped first, so an activity with nothing substantive never
  calls the AI. Returns `{:ok, count}` or `{:error, reason}`.
  """
  def ingest(activity) do
    feedbacks =
      for %{"annotated_text" => annotated} <-
            [activity.feedback | Enum.map(activity.messages, & &1.feedback)],
          do: annotated

    mistakes = Enum.flat_map(feedbacks, &(&1 |> Markers.parse() |> Markers.substantive()))

    if mistakes == [] do
      {:ok, 0}
    else
      config = Settings.get_config()
      sentences = Enum.flat_map(feedbacks, &Markers.mistake_sentences/1)

      with {:ok, cards} <-
             Generator.generate(Enum.join(sentences, "\n"), mistakes,
               target_language: config.target_language,
               native_language: config.native_language,
               language_level: config.language_level
             ) do
        inserted =
          cards
          |> Enum.map(&insert_card(&1, config.target_language, activity.id))
          |> Enum.count(&match?({:ok, %Card{}}, &1))

        {:ok, inserted}
      end
    end
  end

  defp insert_card(%{"target_text" => target_text, "native_text" => native_text}, language, id) do
    if card_exists?(target_text, language) do
      {:ok, :duplicate}
    else
      %Card{}
      |> Card.changeset(%{
        target_text: target_text,
        native_text: native_text,
        language: language,
        source_type: "activity",
        source_id: id,
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
  The distinct cards to study today for the current target language: due reviews and new
  cards, mixed so new material always flows — even behind a big review backlog.

  New cards are guaranteed up to ~half the daily batch; whichever pool (due reviews / new)
  is short, the other fills the slack, capped at `target`. The result is shuffled so new
  cards don't all trail the reviews. Goal is *encountering* `target` distinct cards a day,
  not clearing the whole review backlog first.
  """
  def due_today(target) do
    language = Settings.get_config().target_language
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

    new =
      Repo.all(
        from(c in Card,
          where: is_nil(c.deleted_at) and c.language == ^language and c.state == "new",
          order_by: [asc: c.inserted_at],
          limit: ^target
        )
      )

    {due, new} = split_batch(due, new, target)
    Enum.shuffle(due ++ new)
  end

  # Reserve up to half the batch for new cards so new material always appears, even when
  # due reviews alone could fill `target`. If one pool is short, the other takes the slack.
  defp split_batch(due, new, target) do
    new_reserve = max(1, div(target, 2))
    n_new = min(length(new), new_reserve)
    n_due = min(length(due), target - n_new)
    n_new = min(length(new), target - n_due)
    {Enum.take(due, n_due), Enum.take(new, n_new)}
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

    Repo.transaction(fn ->
      {:ok, updated} = card |> Card.schedule_changeset(fields) |> Repo.update()

      {:ok, _} =
        %Review{}
        |> Review.changeset(%{card_id: card.id, result: result == :pass})
        |> Repo.insert()

      updated
    end)
  end

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

  # ── Completed days ───────────────────────────────────

  @doc "Records `date` as a finished card day. Idempotent."
  def complete_day(date) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(CompletedDay, [%{day: date, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: :day
    )

    :ok
  end

  @doc "Every finished card day, as a `MapSet` of dates."
  def completed_days, do: MapSet.new(Repo.all(from(d in CompletedDay, select: d.day)))

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
