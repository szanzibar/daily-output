defmodule DailyOutput.Conversations.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias DailyOutput.Conversations.Conversation

  schema "messages" do
    field :role, :string
    field :body, :string
    # Per-message proofreading: %{"annotated_text" => ..., "annotations" => [...]}.
    # Only set on user messages, and only once their correction has come back.
    field :feedback, :map

    # Set once this message's corrections have been turned into flashcards, so a continued
    # (and re-completed) conversation never re-cards it. See `Flashcards.ingest_conversation/3`.
    field :flashcards_at, :utc_datetime

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :role, :body])
    |> validate_required([:conversation_id, :role, :body])
    |> validate_inclusion(:role, ["user", "assistant"])
  end

  @doc "Changeset for attaching (already-normalized) per-message correction feedback."
  def feedback_changeset(message, feedback) do
    change(message, feedback: feedback)
  end
end
