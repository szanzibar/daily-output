defmodule DailyOutput.Repo.Migrations.AddAiModelSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :ai_provider, :string, default: "direct"
      add :ai_model, :string, default: "glm-5.2"
    end
  end
end
