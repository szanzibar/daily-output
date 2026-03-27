defmodule Sprachjournal.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :timer_minutes, :integer, default: 5, null: false
      add :target_language, :string, default: "de", null: false
      add :native_language, :string, default: "en", null: false
      add :topics, {:array, :string}, default: []

      timestamps(type: :utc_datetime)
    end
  end
end
