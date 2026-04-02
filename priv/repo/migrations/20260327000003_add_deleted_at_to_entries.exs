defmodule DailyOutput.Repo.Migrations.AddDeletedAtToEntries do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      add :deleted_at, :utc_datetime
    end
  end
end
