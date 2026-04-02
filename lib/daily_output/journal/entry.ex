defmodule DailyOutput.Journal.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entries" do
    field :body, :string
    field :prompt, :string
    field :language, :string, default: "de"
    field :duration, :integer
    field :feedback, :map
    field :completed_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :focus_topic, DailyOutput.FocusTopics.FocusTopic

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
      :deleted_at,
      :focus_topic_id
    ])
    |> validate_required([:language])
  end
end
