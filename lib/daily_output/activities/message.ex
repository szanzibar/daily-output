defmodule DailyOutput.Activities.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :role, :string
    field :body, :string
    # Per-message corrections, %{"annotated_text" => ...}. Only on user messages, once their
    # correction is back.
    field :feedback, :map

    belongs_to :activity, DailyOutput.Activities.Activity

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:activity_id, :role, :body, :feedback])
    |> validate_required([:activity_id, :role, :body])
    |> validate_inclusion(:role, ["user", "assistant"])
  end
end
