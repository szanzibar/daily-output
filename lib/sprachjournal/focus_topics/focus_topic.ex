defmodule Sprachjournal.FocusTopics.FocusTopic do
  use Ecto.Schema
  import Ecto.Changeset

  schema "focus_topics" do
    field :text, :string
    field :source_text, :string
    field :source_type, :string
    field :source_id, :integer
    field :mastered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:text, :source_text, :source_type, :source_id, :mastered_at])
    |> validate_required([:text, :source_type, :source_id])
    |> validate_inclusion(:source_type, ["entry", "conversation"])
  end
end
