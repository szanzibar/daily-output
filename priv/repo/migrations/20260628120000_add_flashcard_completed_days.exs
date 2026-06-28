defmodule DailyOutput.Repo.Migrations.AddFlashcardCompletedDays do
  use Ecto.Migration

  import Ecto.Query

  def up do
    create table(:flashcard_completed_days) do
      add :day, :date, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:flashcard_completed_days, [:day])

    flush()
    backfill_past_completed_days()
  end

  def down do
    drop table(:flashcard_completed_days)
  end

  # One-time grandfather: the per-day flashcard target was never recorded, so historical
  # completion can't be re-derived after a cap change. Mark every PAST logical date that has
  # reviews as completed, preserving days already earned. A fresh DB has no reviews yet, so
  # this is a no-op there.
  defp backfill_past_completed_days do
    today = DailyOutput.Clock.today()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      from(r in "flashcard_reviews",
        where: not is_nil(r.card_id),
        select: type(r.inserted_at, :utc_datetime)
      )
      |> repo().all()
      |> Enum.map(&DailyOutput.Clock.to_logical_date/1)
      |> Enum.uniq()
      |> Enum.filter(&(Date.compare(&1, today) == :lt))
      |> Enum.map(&%{day: &1, inserted_at: now})

    if rows != [], do: repo().insert_all("flashcard_completed_days", rows)
  end
end
