defmodule DailyOutput.Flashcards.CompletedDay do
  use Ecto.Schema

  @moduledoc """
  A logical date whose flashcard quota was met — recorded once, as a settled fact.

  Completion used to be recomputed from the review log against the *current* daily target,
  so changing `flashcards_per_day` retroactively re-judged every past day. Recording the
  outcome here instead means a day that was earned stays earned, no matter how the target
  changes later.
  """

  schema "flashcard_completed_days" do
    field :day, :date

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
