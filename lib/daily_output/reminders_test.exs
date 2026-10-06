defmodule DailyOutput.RemindersTest do
  # Not async: push_device/1 sets the global VAPID keys.
  use DailyOutput.DataCase

  alias DailyOutput.{Clock, Reminders, Settings}
  alias DailyOutput.Settings.Config

  @today ~D[2026-06-17]
  @evening DateTime.new!(@today, ~T[20:30:00], "Etc/UTC")
  @afternoon DateTime.new!(@today, ~T[15:00:00], "Etc/UTC")

  defp config(overrides) do
    struct(%Config{reminder_time: ~T[20:00:00]}, overrides)
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

  test "not due if one was already sent today (dedupe)" do
    refute Reminders.due?(config(last_reminder_on: @today), @evening, @today, false)
  end

  test "due again on a new day even if yesterday's was sent" do
    assert Reminders.due?(config(last_reminder_on: ~D[2026-06-16]), @evening, @today, false)
  end

  describe "maybe_remind/0" do
    setup do
      {:ok, config} = Settings.ensure_config()
      Settings.update_config(config, %{reminder_time: ~T[00:00:00]})
      :ok
    end

    test "skips when no device is subscribed" do
      assert Reminders.maybe_remind() == :skip
    end

    test "sends once a day and remembers the day" do
      push_device(201)

      assert Reminders.maybe_remind() == :sent
      assert Settings.get_config().last_reminder_on == Clock.today()
      assert Reminders.maybe_remind() == :skip
    end
  end

  test "the reminder speaks the UI language, auto included" do
    config = %Config{ui_language: "auto", language_level: "B2", target_language: "de"}

    assert Reminders.notification(config, 3).body ==
             "Deine 3-Tage-Serie wartet. Die Übung für heute ist bereit."
  end
end
