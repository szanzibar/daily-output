defmodule DailyOutput.Repo.Migrations.AddUiLanguageToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :ui_language, :string, default: "auto"
    end
  end
end
