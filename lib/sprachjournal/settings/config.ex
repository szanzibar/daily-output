defmodule Sprachjournal.Settings.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :timer_minutes, :integer, default: 5
    field :target_language, :string, default: "de"
    field :native_language, :string, default: "en"
    field :topics, {:array, :string}, default: []
    field :language_level, :string, default: "B2"
    field :prompt_context, :string, default: ""
    field :min_exchanges, :integer, default: 5

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :timer_minutes,
      :target_language,
      :native_language,
      :topics,
      :language_level,
      :prompt_context,
      :min_exchanges
    ])
    |> validate_required([:timer_minutes, :target_language, :native_language])
    |> validate_number(:timer_minutes, greater_than: 0, less_than_or_equal_to: 60)
  end
end
