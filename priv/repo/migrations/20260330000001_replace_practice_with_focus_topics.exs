defmodule DailyOutput.Repo.Migrations.ReplacePracticeWithFocusTopics do
  use Ecto.Migration

  def change do
    create table(:focus_topics) do
      add :text, :string, null: false
      add :source_type, :string, null: false
      add :source_id, :integer, null: false
      add :mastered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    alter table(:entries) do
      add :focus_topic_id, references(:focus_topics, on_delete: :nilify_all)
    end

    alter table(:conversations) do
      add :focus_topic_id, references(:focus_topics, on_delete: :nilify_all)
    end

    # practice_enabled and practiced_at columns left in DB (harmless)
  end
end
