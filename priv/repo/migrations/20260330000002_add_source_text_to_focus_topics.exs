defmodule Sprachjournal.Repo.Migrations.AddSourceTextToFocusTopics do
  use Ecto.Migration

  def change do
    alter table(:focus_topics) do
      add :source_text, :text
    end
  end
end
