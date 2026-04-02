defmodule DailyOutput.Repo.Migrations.CreateEntries do
  use Ecto.Migration

  def change do
    create table(:entries) do
      add :body, :text
      add :prompt, :text
      add :language, :string, default: "de", null: false
      add :duration, :integer
      add :feedback, :map
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
