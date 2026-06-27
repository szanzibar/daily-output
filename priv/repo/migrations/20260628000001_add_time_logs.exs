defmodule DailyOutput.Repo.Migrations.AddTimeLogs do
  use Ecto.Migration

  def change do
    # One accumulating row per logical day per section ("entry"/"conversation"/
    # "flashcards"); active foreground seconds are added via upsert as you work.
    create table(:time_logs) do
      add :day, :date, null: false
      add :section, :string, null: false
      add :seconds, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:time_logs, [:day, :section])
  end
end
