defmodule DailyOutput.Clock do
  @moduledoc """
  Local-time helpers for the app's habit math.

  Everything used to run on UTC, which makes "did I practice today?" and "remind me at
  8pm" wrong for anyone not on UTC. This centralizes two ideas:

    * the user's configured timezone (falls back to `:default_timezone` / UTC), and
    * a **4am day boundary** — the logical day runs 4am→4am, so a late-night session
      still counts as "today" rather than tripping into tomorrow.
  """

  alias DailyOutput.Settings

  @day_start ~T[04:00:00]

  @doc "The configured IANA timezone, or the configured default, or UTC."
  def timezone do
    case Settings.get_config().timezone do
      tz when is_binary(tz) and tz != "" -> tz
      _ -> default_timezone()
    end
  end

  def default_timezone do
    Application.get_env(:daily_output, :default_timezone) || "Etc/UTC"
  end

  @doc "Current `DateTime` in the given (or configured) timezone."
  def now(tz \\ nil), do: DateTime.now!(tz || timezone())

  @doc "The current logical date (4am boundary) in the given (or configured) timezone."
  def today(tz \\ nil) do
    tz = tz || timezone()
    logical_date(now(tz))
  end

  @doc """
  The UTC `{start, end}` half-open range covering logical day `date` in `tz`.
  Suitable for comparing against `inserted_at` (stored in UTC).
  """
  def day_range(date, tz \\ nil) do
    tz = tz || timezone()
    start_utc = date |> DateTime.new!(@day_start, tz) |> DateTime.shift_zone!("Etc/UTC")

    end_utc =
      date |> Date.add(1) |> DateTime.new!(@day_start, tz) |> DateTime.shift_zone!("Etc/UTC")

    {start_utc, end_utc}
  end

  @doc "The logical date a UTC (or any-zone) datetime falls on, in the configured timezone."
  def to_logical_date(%DateTime{} = dt, tz \\ nil) do
    tz = tz || timezone()
    dt |> DateTime.shift_zone!(tz) |> logical_date()
  end

  defp logical_date(%DateTime{} = dt) do
    date = DateTime.to_date(dt)
    if Time.compare(DateTime.to_time(dt), @day_start) == :lt, do: Date.add(date, -1), else: date
  end
end
