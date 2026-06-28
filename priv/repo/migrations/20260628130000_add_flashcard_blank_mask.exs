defmodule DailyOutput.Repo.Migrations.AddFlashcardBlankMask do
  use Ecto.Migration

  def change do
    alter table(:flashcards) do
      # Progressive difficulty: the set of word indices (into the whitespace-tokenized
      # target_text) that are still hidden as fill-in-the-blank. `nil` means the whole
      # answer is hidden (a brand-new card you type in full). Each miss narrows this to
      # only the words still gotten wrong; a pass holds it steady.
      add :blank_indices, {:array, :integer}
    end
  end
end
