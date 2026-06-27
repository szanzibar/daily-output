defmodule DailyOutput.Stats.TimeLog do
  use Ecto.Schema

  @moduledoc """
  Accumulated active time (seconds) for one logical day and section. Written by upsert —
  see `DailyOutput.Stats.track/2`.
  """

  schema "time_logs" do
    field :day, :date
    field :section, :string
    field :seconds, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
