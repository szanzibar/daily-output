defmodule DailyOutput.Repo.Migrations.SelfManagedPush do
  use Ecto.Migration

  def change do
    # Auto-generated VAPID keypair, persisted in the data volume alongside the
    # SQLite file so a bare `docker run` has working push without manual setup.
    create table(:vapid_keys) do
      add :public_key, :text, null: false
      add :private_key, :text, null: false

      timestamps(type: :utc_datetime)
    end

    # Reminders are now per-device: a device is "on" iff it has a push
    # subscription, so the global on/off flag is gone.
    alter table(:settings) do
      remove :reminders_enabled, :boolean, default: false, null: false
    end
  end
end
