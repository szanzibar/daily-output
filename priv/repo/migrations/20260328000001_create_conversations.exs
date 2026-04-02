defmodule DailyOutput.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :topic, :text
      add :language, :string, default: "de", null: false
      add :feedback, :map
      add :completed_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
