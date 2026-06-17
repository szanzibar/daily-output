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

  def list_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    Entry
    |> not_deleted()
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
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

  def change_entry(%Entry{} = entry, attrs \\ %{}) do
    Entry.changeset(entry, attrs)
  end

  def word_count(%Entry{body: nil}), do: 0

  def word_count(%Entry{body: body}) do
    body |> String.split(~r/\s+/, trim: true) |> length()
  end

  def current_streak do
    entries =
      Entry
      |> not_deleted()
      |> where([e], not is_nil(e.completed_at))
      |> select([e], fragment("date(?, 'unixepoch')", e.inserted_at))
      |> distinct(true)
      |> order_by([e], desc: e.inserted_at)
      |> Repo.all()

    count_consecutive_days(entries)
  end

  defp count_consecutive_days([]), do: 0

  defp count_consecutive_days(dates) do
    today = Clock.today() |> Date.to_iso8601()

    dates
    |> Enum.map(&to_string/1)
    |> count_from(today, 0)
  end

  defp count_from(dates, expected_date, count) do
    if expected_date in dates do
      prev = expected_date |> Date.from_iso8601!() |> Date.add(-1) |> Date.to_iso8601()
      count_from(dates, prev, count + 1)
    else
      count
    end
  end
end
