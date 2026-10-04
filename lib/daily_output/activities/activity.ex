defmodule DailyOutput.Activities.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  alias DailyOutput.Activities.Message

  schema "activities" do
    field :kind, :string
    # The logical day (see `Clock`), stamped at creation so queries never do day-range math.
    field :date, :date
    field :prompt, :string
    field :angle, :string
    # %{"category" => ..., "title" => ..., "body" => ...}
    field :focus, :map
    field :body, :string
    field :feedback, :map
    field :summary, :string
    field :completed_at, :utc_datetime

    has_many :messages, Message, preload_order: [asc: :id]

    timestamps(type: :utc_datetime)
  end

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :kind,
      :date,
      :prompt,
      :angle,
      :focus,
      :body,
      :feedback,
      :summary,
      :completed_at
    ])
    |> validate_required([:kind, :date])
    |> validate_inclusion(:kind, ~w(conversation journal))
  end
end
