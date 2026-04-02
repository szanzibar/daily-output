defmodule DailyOutput.Repo.Migrations.AddPromptSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :language_level, :string, default: "B2"
      add :prompt_context, :text, default: ""
    end
  end
end
