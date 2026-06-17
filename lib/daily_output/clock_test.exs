defmodule DailyOutput.ClockTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Clock

  describe "day_range/2 (4am boundary)" do
    test "summer Berlin day runs 02:00Z → 02:00Z (UTC+2)" do
      {start_utc, end_utc} = Clock.day_range(~D[2026-06-17], "Europe/Berlin")
      assert start_utc == ~U[2026-06-17 02:00:00Z]
      assert end_utc == ~U[2026-06-18 02:00:00Z]
    end

    test "UTC day runs 04:00Z → 04:00Z" do
      {start_utc, end_utc} = Clock.day_range(~D[2026-06-17], "Etc/UTC")
      assert start_utc == ~U[2026-06-17 04:00:00Z]
      assert end_utc == ~U[2026-06-18 04:00:00Z]
    end
  end

  describe "to_logical_date/2 (late night counts as the same day)" do
    test "3am local is still the previous logical day" do
      # 01:00Z == 03:00 CEST, before the 4am boundary
      assert Clock.to_logical_date(~U[2026-06-17 01:00:00Z], "Europe/Berlin") == ~D[2026-06-16]
    end

    test "5am local is the new logical day" do
      # 03:00Z == 05:00 CEST, after the 4am boundary
      assert Clock.to_logical_date(~U[2026-06-17 03:00:00Z], "Europe/Berlin") == ~D[2026-06-17]
    end
  end

  test "timezone/0 falls back to UTC when unset" do
    assert Clock.default_timezone() == "Etc/UTC"
  end
end
