defmodule DailyOutput.Repo.Migrations.AddRemindersAndPush do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :timezone, :string
      add :reminders_enabled, :boolean, default: false, null: false
      add :reminder_time, :time, default: "20:00:00", null: false
      add :last_reminder_on, :date
    end

    create table(:push_subscriptions) do
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
  end
end
