defmodule Sprachjournal.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Sprachjournal.Conversations.Message

  schema "conversations" do
    field :topic, :string
    field :language, :string, default: "de"
    field :feedback, :map
    field :completed_at, :utc_datetime
    field :deleted_at, :utc_datetime

    has_many :messages, Message, preload_order: [asc: :inserted_at]
    belongs_to :focus_topic, Sprachjournal.FocusTopics.FocusTopic

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:topic, :language, :feedback, :completed_at, :deleted_at, :focus_topic_id])
    |> validate_required([:language])
  end
end
