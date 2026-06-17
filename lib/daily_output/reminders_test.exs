defmodule DailyOutput.RemindersTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Reminders
  alias DailyOutput.Settings.Config

  @today ~D[2026-06-17]
  @evening DateTime.new!(@today, ~T[20:30:00], "Etc/UTC")
  @afternoon DateTime.new!(@today, ~T[15:00:00], "Etc/UTC")

  defp config(overrides) do
    struct(%Config{reminders_enabled: true, reminder_time: ~T[20:00:00]}, overrides)
  end

  test "due after the reminder time when the day isn't done" do
    assert Reminders.due?(config([]), @evening, @today, false)
  end

  test "not due before the reminder time" do
    refute Reminders.due?(config([]), @afternoon, @today, false)
  end

  test "not due once today's goal is done" do
    refute Reminders.due?(config([]), @evening, @today, true)
  end

  test "not due when reminders are disabled" do
    refute Reminders.due?(config(reminders_enabled: false), @evening, @today, false)
  end

  test "not due if one was already sent today (dedupe)" do
    refute Reminders.due?(config(last_reminder_on: @today), @evening, @today, false)
  end

  test "due again on a new day even if yesterday's was sent" do
    assert Reminders.due?(config(last_reminder_on: ~D[2026-06-16]), @evening, @today, false)
  end
end
