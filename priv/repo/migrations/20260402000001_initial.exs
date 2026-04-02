defmodule DailyOutput.Repo.Migrations.Initial do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :timer_minutes, :integer, default: 5, null: false
      add :target_language, :string, default: "de", null: false
      add :native_language, :string, default: "en", null: false
      add :topics, {:array, :string}, default: []
      add :language_level, :string, default: "B2"
      add :prompt_context, :text, default: ""
      add :min_exchanges, :integer, default: 5
      add :ui_language, :string, default: "auto"

      timestamps(type: :utc_datetime)
    end

    create table(:focus_topics) do
      add :text, :string, null: false
      add :source_text, :text
      add :source_type, :string, null: false
      add :source_id, :integer, null: false
      add :mastered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:entries) do
      add :body, :text
      add :prompt, :text
      add :language, :string, default: "de", null: false
      add :duration, :integer
      add :feedback, :map
      add :completed_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :focus_topic_id, references(:focus_topics, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create table(:conversations) do
      add :topic, :text
      add :language, :string, default: "de", null: false
      add :feedback, :map
      add :completed_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :focus_topic_id, references(:focus_topics, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:conversation_id])

    create table(:cache) do
      add :key, :string, null: false
      add :value, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cache, [:key])
  end
end
