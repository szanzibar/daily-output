defmodule DailyOutput.Repo.Migrations.AddFeedbackToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :feedback, :map
    end
  end
end
