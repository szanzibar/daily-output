defmodule DailyOutput.Journal do
  @moduledoc """
  Context for managing journal entries.
  Multiple entries per day = versioning. Latest non-deleted entry per day is the "current" version.
  """

  import Ecto.Query
  alias DailyOutput.Clock
  alias DailyOutput.Repo
  alias DailyOutput.AI.Proofreader
  alias DailyOutput.Journal.Entry

  defp not_deleted(query) do
    from(e in query, where: is_nil(e.deleted_at))
  end

  @doc """
  Returns the latest entry per day for the last N days, excluding today.
  Groups by date, picks the most recent per day.
  """
  def list_recent_entries(days \\ 14) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400)
    {today_start, _} = Clock.day_range(Clock.today())

    # Get all non-deleted entries in range, then group by date in Elixir
    entries =
      Entry
      |> not_deleted()
      |> where([e], e.inserted_at >= ^cutoff and e.inserted_at < ^today_start)
      |> order_by([e], desc: e.inserted_at)
      |> Repo.all()

    # Group by logical date, take the latest (first) from each group
    entries
    |> Enum.group_by(fn e -> Clock.to_logical_date(e.inserted_at) end)
    |> Enum.map(fn {_date, [latest | _]} -> latest end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  def get_entry!(id) do
    entry =
      Entry
      |> not_deleted()
      |> Repo.get!(id)

    %{entry | feedback: Proofreader.normalize_feedback(entry.feedback)}
  end

  @doc "Returns the latest non-deleted entry for today."
  def get_today_entry do
    {today_start, today_end} = Clock.day_range(Clock.today())

    Entry
    |> not_deleted()
    |> where([e], e.inserted_at >= ^today_start and e.inserted_at < ^today_end)
    |> order_by([e], desc: e.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns all non-deleted entries for the same date as the given entry."
  def get_versions(%Entry{} = entry) do
    date = Clock.to_logical_date(entry.inserted_at)
    get_entries_for_date(date)
  end

  @doc "Returns all non-deleted entries for a given date, newest first."
  def get_entries_for_date(%Date{} = date) do
    {day_start, day_end} = Clock.day_range(date)

    Entry
    |> not_deleted()
    |> where([e], e.inserted_at >= ^day_start and e.inserted_at < ^day_end)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc "Returns {version_number, total_versions} for the given entry among its day's entries."
  def version_info(%Entry{} = entry) do
    versions = get_versions(entry)
    total = length(versions)
    # versions is newest-first, so reverse to get chronological order for numbering
    chronological = Enum.reverse(versions)
    idx = Enum.find_index(chronological, &(&1.id == entry.id))
    {(idx || 0) + 1, total}
  end

  def create_entry(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  def update_entry(%Entry{} = entry, attrs) do
    entry
    |> Entry.changeset(attrs)
    |> Repo.update()
  end

  def complete_entry(%Entry{} = entry) do
    entry
    |> Entry.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def save_feedback(%Entry{} = entry, feedback) do
    normalized_feedback = Proofreader.normalize_feedback(feedback)

    entry
    |> Entry.changeset(%{feedback: normalized_feedback})
    |> Repo.update()
  end

  def soft_delete_entry(%Entry{} = entry) do
    entry
    |> Entry.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def word_count(%Entry{body: nil}), do: 0

  def word_count(%Entry{body: body}) do
    count_words(body)
  end

  # ── Writing floor (soft timer) ───────────────────────
  #
  # The writing timer is a gentle *target*, not a lock. "Done" unlocks as soon as a
  # draft clears this low word floor, so a quick warm-up still counts (one task keeps
  # the streak — see `FocusTopics.day_status/1`).
  @floor_words 25

  @doc "Minimum words that unlock finishing a draft entry."
  def floor_words, do: @floor_words

  @doc "How many more words until a draft clears the floor (0 once met)."
  def words_until_floor(body) when is_binary(body), do: max(@floor_words - count_words(body), 0)
  def words_until_floor(_), do: @floor_words

  @doc "True once a draft has enough writing to finish."
  def floor_met?(body), do: words_until_floor(body) == 0

  defp count_words(nil), do: 0
  defp count_words(body), do: body |> String.split(~r/\s+/, trim: true) |> length()
end
