defmodule DailyOutput.Repo.Migrations.AddFlashcards do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :flashcards_per_day, :integer, default: 15, null: false
    end

    create table(:flashcards) do
      # The card itself: type the target-language answer when shown the native prompt.
      add :target_text, :text, null: false
      add :native_text, :text, null: false
      add :language, :string, null: false

      # Where this card came from (provenance / debugging only).
      add :source_type, :string
      add :source_id, :integer

      # Spaced-repetition state (SM-2 adapted to binary pass/fail).
      add :state, :string, default: "new", null: false
      add :due_at, :utc_datetime
      add :interval_days, :integer, default: 0, null: false
      add :ease, :float, default: 2.5, null: false
      add :reps, :integer, default: 0, null: false
      add :lapses, :integer, default: 0, null: false
      add :last_reviewed_at, :utc_datetime

      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:flashcards, [:due_at])
    create index(:flashcards, [:state])
    create index(:flashcards, [:language])
    create index(:flashcards, [:target_text])

    # Lightweight activity log: the source of truth for "how many distinct cards did I
    # study on day X?" (daily quota + streak) and for future stats.
    create table(:flashcard_reviews) do
      add :card_id, references(:flashcards, on_delete: :nilify_all)
      add :result, :boolean, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:flashcard_reviews, [:inserted_at])
    create index(:flashcard_reviews, [:card_id])
  end
end
