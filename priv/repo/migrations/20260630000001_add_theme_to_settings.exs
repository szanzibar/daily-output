defmodule DailyOutput.Repo.Migrations.AddThemeToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :theme, :string, default: "auto"
    end
  end
end
