defmodule DailyOutput.Flashcards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(new learning review relearning)

  schema "flashcards" do
    field :target_text, :string
    field :native_text, :string
    field :language, :string

    field :source_type, :string
    field :source_id, :integer

    field :state, :string, default: "new"
    field :due_at, :utc_datetime
    field :interval_days, :integer, default: 0
    field :ease, :float, default: 2.5
    field :reps, :integer, default: 0
    field :lapses, :integer, default: 0
    field :last_reviewed_at, :utc_datetime

    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Creation / ingest changeset (card content)."
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :target_text,
      :native_text,
      :language,
      :source_type,
      :source_id,
      :state,
      :due_at,
      :interval_days,
      :ease,
      :reps,
      :lapses,
      :last_reviewed_at,
      :deleted_at
    ])
    |> validate_required([:target_text, :native_text, :language])
    |> validate_inclusion(:state, @states)
  end

  @doc "User edit changeset — only the two text sides are editable."
  def edit_changeset(card, attrs) do
    card
    |> cast(attrs, [:target_text, :native_text])
    |> validate_required([:target_text, :native_text])
  end

  @doc "Applies the scheduler's computed SR fields after a review."
  def schedule_changeset(card, fields) do
    card
    |> cast(fields, [:state, :due_at, :interval_days, :ease, :reps, :lapses, :last_reviewed_at])
    |> validate_inclusion(:state, @states)
  end
end
