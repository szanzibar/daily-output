defmodule DailyOutput.Repo.Migrations.AddAiProviderToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :ai_provider, :string, default: "anthropic", null: false
    end
  end
end
