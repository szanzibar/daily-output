defmodule DailyOutput.Repo.Migrations.Initial do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :target_language, :string, default: "de", null: false
      add :native_language, :string, default: "en", null: false
      add :language_level, :string, default: "B2"
      add :about_you, :text, default: ""
      add :ui_language, :string, default: "auto"
      add :theme, :string, default: "auto"
      add :ai_model, :string, default: "sonnet-5.5"
      add :ai_provider, :string, default: "direct"
      add :timezone, :string
      add :reminder_time, :time, default: "20:00:00", null: false
      add :last_reminder_on, :date

      timestamps(type: :utc_datetime)
    end

    create table(:activities) do
      add :kind, :string, null: false
      add :date, :date, null: false
      add :prompt, :text
      add :angle, :string
      add :focus, :map
      add :body, :text
      add :feedback, :map
      add :summary, :text
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:activities, [:date])

    create table(:messages) do
      add :activity_id, references(:activities, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :body, :text, null: false
      add :feedback, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:activity_id])

    create table(:flashcards) do
      add :target_text, :text, null: false
      add :native_text, :text, null: false
      add :language, :string, null: false
      add :source_type, :string
      add :source_id, :integer
      add :state, :string, default: "new", null: false
      add :due_at, :utc_datetime
      add :interval_days, :integer, default: 0, null: false
      add :ease, :float, default: 2.5, null: false
      add :reps, :integer, default: 0, null: false
      add :lapses, :integer, default: 0, null: false
      add :last_reviewed_at, :utc_datetime
      add :blank_indices, {:array, :integer}
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:flashcards, [:due_at])
    create index(:flashcards, [:state])
    create index(:flashcards, [:language])
    create index(:flashcards, [:target_text])

    create table(:flashcard_reviews) do
      add :card_id, references(:flashcards, on_delete: :nilify_all)
      add :result, :boolean, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:flashcard_reviews, [:inserted_at])
    create index(:flashcard_reviews, [:card_id])

    create table(:flashcard_completed_days) do
      add :day, :date, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:flashcard_completed_days, [:day])

    create table(:push_subscriptions) do
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])

    create table(:vapid_keys) do
      add :public_key, :text, null: false
      add :private_key, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:api_usages) do
      add :purpose, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, default: 0, null: false
      add :output_tokens, :integer, default: 0, null: false
      add :cache_read_tokens, :integer, default: 0, null: false
      add :cache_creation_tokens, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_usages, [:inserted_at])
    create index(:api_usages, [:purpose])

    create table(:time_logs) do
      add :day, :date, null: false
      add :section, :string, null: false
      add :seconds, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:time_logs, [:day, :section])
  end
end
