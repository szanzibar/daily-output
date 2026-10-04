defmodule DailyOutput.Focus do
  @moduledoc """
  Picks today's grammar focus from your mistakes. Pure: the caller passes the history and the
  date seeds the pick, so a refresh never changes it.
  """

  # Too shallow to build a focus around.
  @ignored ~w(spelling punctuation other)

  @doc """
  A correction category, weighted by how often it shows up in `categories` (one entry per
  correction). Skips `recent_focus_categories` so the focus rotates. `nil` when nothing is
  left, like on a cold start.
  """
  def choose(categories, recent_focus_categories, date) do
    weights =
      categories
      |> Enum.reject(&(&1 in @ignored or &1 in recent_focus_categories))
      |> Enum.frequencies()
      |> Enum.sort()

    total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total > 0 do
      roll = :erlang.phash2({:focus, date}, total)

      Enum.reduce_while(weights, roll, fn {category, count}, left ->
        if left < count, do: {:halt, category}, else: {:cont, left - count}
      end)
    end
  end
end
