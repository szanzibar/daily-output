defmodule DailyOutput.Repo.Migrations.AddMinExchangesToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :min_exchanges, :integer, default: 5
    end
  end
end
