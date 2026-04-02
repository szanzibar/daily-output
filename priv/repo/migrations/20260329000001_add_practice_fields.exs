defmodule DailyOutput.Repo.Migrations.AddPracticeFields do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      add :practiced_at, :utc_datetime
    end

    alter table(:conversations) do
      add :practiced_at, :utc_datetime
    end

    alter table(:settings) do
      add :practice_enabled, :boolean, default: true
    end
  end
end
