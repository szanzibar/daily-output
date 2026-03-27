defmodule Sprachjournal.Repo.Migrations.CreateCache do
  use Ecto.Migration

  def change do
    create table(:cache) do
      add :key, :string, null: false
      add :value, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cache, [:key])
  end
end
