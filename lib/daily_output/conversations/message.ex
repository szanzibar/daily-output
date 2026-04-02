defmodule DailyOutput.Conversations.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias DailyOutput.Conversations.Conversation

  schema "messages" do
    field :role, :string
    field :body, :string

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :role, :body])
    |> validate_required([:conversation_id, :role, :body])
    |> validate_inclusion(:role, ["user", "assistant"])
  end
end
