defmodule Sprachjournal.Journal.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entries" do
    field :body, :string
    field :prompt, :string
    field :language, :string, default: "de"
    field :duration, :integer
    field :feedback, :map
    field :completed_at, :utc_datetime
    field :practiced_at, :utc_datetime
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :body,
      :prompt,
      :language,
      :duration,
      :feedback,
      :completed_at,
      :practiced_at,
      :deleted_at
    ])
    |> validate_required([:language])
  end
end
