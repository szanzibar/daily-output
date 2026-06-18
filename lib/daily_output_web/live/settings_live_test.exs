defmodule DailyOutputWeb.SettingsLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Push, Settings}

  test "the main form auto-saves on change and toasts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", config: %{timer_minutes: "9", language_level: "C1"})
    |> render_change()

    config = Settings.get_config()
    assert config.timer_minutes == 9
    assert config.language_level == "C1"
    assert_push_event(view, "toast", %{kind: "info"})
  end

  test "invalid input is rejected and the previous value stays saved", %{conn: conn} do
    {:ok, config} = Settings.ensure_config()
    {:ok, _} = Settings.update_config(config, %{timer_minutes: 5})

    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#settings-form", config: %{timer_minutes: "0"})
      |> render_change()

    # zero is out of range → not saved, error shown inline
    assert Settings.get_config().timer_minutes == 5
    assert html =~ "less than or equal to" or html =~ "must be"
  end

  test "set_timezone stores a valid timezone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "set_timezone", %{"timezone" => "Europe/Berlin"})

    assert Settings.get_config().timezone == "Europe/Berlin"
  end

  test "set_timezone rejects an unknown timezone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "set_timezone", %{"timezone" => "Mars/Phobos"})

    assert is_nil(Settings.get_config().timezone)
  end

  test "save_reminder_time parses HH:MM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "save_reminder_time", %{"reminder_time" => "07:30"})

    assert Settings.get_config().reminder_time == ~T[07:30:00]
  end

  test "enable then disable reminders toggles the flag and subscription", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    subscription = %{
      "endpoint" => "https://push.example/xyz",
      "keys" => %{"p256dh" => "pkey", "auth" => "akey"}
    }

    render_hook(view, "enable_reminders", %{"subscription" => subscription})

    assert Settings.get_config().reminders_enabled
    assert [_] = Push.list_subscriptions()

    render_hook(view, "disable_reminders", %{"endpoint" => "https://push.example/xyz"})

    refute Settings.get_config().reminders_enabled
    assert Push.list_subscriptions() == []
  end

  test "test_notification pushes an error toast when nothing could be sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "test_notification", %{})

    assert_push_event(view, "toast", %{kind: "error"})
  end
end
