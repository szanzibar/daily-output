defmodule DailyOutput.Flashcards.Review do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  One review event. The log of these rows is the source of truth for the daily quota
  (distinct cards studied per logical day) and the flashcard streak history.
  """

  schema "flashcard_reviews" do
    field :result, :boolean

    belongs_to :card, DailyOutput.Flashcards.Card

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [:result, :card_id])
    |> validate_required([:result])
  end
end
