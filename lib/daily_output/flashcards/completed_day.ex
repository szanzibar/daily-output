defmodule DailyOutput.Flashcards.CompletedDay do
  use Ecto.Schema

  @moduledoc """
  A logical date whose card session was finished, or had nothing due. Recorded because which
  cards were due on a past day can't be derived later.
  """

  schema "flashcard_completed_days" do
    field :day, :date

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
