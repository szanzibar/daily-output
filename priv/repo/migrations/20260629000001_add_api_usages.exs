defmodule DailyOutput.Repo.Migrations.AddApiUsages do
  use Ecto.Migration

  def change do
    # One row per Anthropic API call, written from the AI.chat/2 chokepoint.
    # `purpose` tags the feature ("proofread"/"flashcards"/...), `model` is the
    # model the response reports it used. Tokens are stored raw; dollar cost is
    # computed at read time from a pricing table so price changes recompute history.
    create table(:api_usages) do
      add :purpose, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, default: 0, null: false
      add :output_tokens, :integer, default: 0, null: false
      add :cache_read_tokens, :integer, default: 0, null: false
      add :cache_creation_tokens, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_usages, [:inserted_at])
    create index(:api_usages, [:purpose])
  end
end
