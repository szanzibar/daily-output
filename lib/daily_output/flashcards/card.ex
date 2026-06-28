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

    # Progressive fill-in-the-blank mask: word indices still hidden (nil = whole answer
    # hidden). See `DailyOutput.Flashcards.Cloze`.
    field :blank_indices, {:array, :integer}

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
      :blank_indices,
      :deleted_at
    ])
    |> validate_required([:target_text, :native_text, :language])
    |> validate_inclusion(:state, @states)
  end

  @doc """
  User edit changeset — only the two text sides are editable.

  Editing the answer text invalidates the fill-in-the-blank mask (the word indices no
  longer line up), so changing `target_text` resets the card to a full-answer prompt.
  """
  def edit_changeset(card, attrs) do
    card
    |> cast(attrs, [:target_text, :native_text])
    |> validate_required([:target_text, :native_text])
    |> reset_mask_on_text_change()
  end

  defp reset_mask_on_text_change(changeset) do
    case fetch_change(changeset, :target_text) do
      {:ok, _new} -> put_change(changeset, :blank_indices, nil)
      :error -> changeset
    end
  end

  @doc "Applies the scheduler's computed SR fields (and any new blank mask) after a review."
  def schedule_changeset(card, fields) do
    card
    |> cast(fields, [
      :state,
      :due_at,
      :interval_days,
      :ease,
      :reps,
      :lapses,
      :last_reviewed_at,
      :blank_indices
    ])
    |> validate_inclusion(:state, @states)
  end
end
