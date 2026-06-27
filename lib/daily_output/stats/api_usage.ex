defmodule DailyOutput.Stats.ApiUsage do
  use Ecto.Schema

  @moduledoc """
  One Anthropic API call's token usage, recorded from `DailyOutput.AI.chat/2`.

  Tokens are stored raw; the dollar cost is derived at read time from the pricing
  table in `DailyOutput.Stats`, keyed by `model`. See `DailyOutput.Stats.record_usage/2`.
  """

  schema "api_usages" do
    field :purpose, :string
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
