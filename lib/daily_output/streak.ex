defmodule DailyOutput.Streak do
  @moduledoc """
  The streak, derived from per-day facts. Pure.

  A day passes with at least one activity and the card session done. Doing both activities
  banks a freeze, and a freeze covers one missed day. A day that's still open never breaks
  the streak.
  """

  @max_freezes 3

  @doc """
  `days` maps each date to `%{activities: n, cards?: bool}`. Returns
  `%{count, freezes_available, today_status}`, where `today_status` is `:pending`,
  `:passed`, or `:bonus` (passed with both activities).
  """
  def compute(days, today) do
    first = days |> Map.keys() |> Enum.min(Date, fn -> today end)

    past =
      first
      |> Date.range(Date.add(today, -1), 1)
      |> Enum.reduce({0, 0}, &walk(status(days[&1]), &2))

    today_status = status(days[today])
    {count, freezes} = if today_status == :pending, do: past, else: walk(today_status, past)

    %{count: count, freezes_available: freezes, today_status: today_status}
  end

  @doc "The most freezes you can bank."
  def max_freezes, do: @max_freezes

  defp status(%{activities: n, cards?: true}) when n >= 2, do: :bonus
  defp status(%{activities: n, cards?: true}) when n >= 1, do: :passed
  defp status(_), do: :pending

  # A past day that's still :pending was missed.
  defp walk(:bonus, {count, freezes}), do: {count + 1, min(freezes + 1, @max_freezes)}
  defp walk(:passed, {count, freezes}), do: {count + 1, freezes}
  defp walk(:pending, {count, freezes}) when freezes > 0, do: {count, freezes - 1}
  defp walk(:pending, _), do: {0, 0}
end
