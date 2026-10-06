defmodule DailyOutputWeb.SettingsLiveTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{Push, Settings}

  test "the main form auto-saves on change and toasts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", config: %{about_you: "I sing in a choir.", language_level: "C1"})
    |> render_change()

    config = Settings.get_config()
    assert config.about_you == "I sing in a choir."
    assert config.language_level == "C1"
    assert_push_event(view, "toast", %{kind: "info"})
  end

  test "English needs no translation files: the msgids are the English UI", %{conn: conn} do
    {:ok, config} = Settings.ensure_config()
    Settings.update_config(config, %{ui_language: "en"})

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "h1", "Settings")
    assert has_element?(view, "#reminders-panel h2", "Daily Reminder")
  end

  test "the About you field keeps a local draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             ~s(#config_about_you[phx-hook="AutoExpand"][data-persist-key="settings-about-you"])
           )
  end

  test "invalid input is rejected and the previous value stays saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_change(view, "save_form", %{"config" => %{"ai_model" => "gpt-9"}})

    assert Settings.get_config().ai_model == "gpt-6.1-sol"
    # The UI defaults to German (auto at B2), errors included.
    assert has_element?(view, "#settings-form", "ist ungültig")
  end

  test "AI section saves model/provider and its key status follows the choice", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert has_element?(view, "#ai-models", "77.6")
    assert has_element?(view, "#ai-models", "65.0")
    # Default direct + Sol → OpenAI's own API.
    assert html =~ "OPENAI_API_KEY"

    html =
      view
      |> form("#settings-form", config: %{ai_provider: "openrouter", ai_model: "gpt-6-luna"})
      |> render_change()

    config = Settings.get_config()
    assert config.ai_provider == "openrouter"
    assert config.ai_model == "gpt-6-luna"

    # OpenRouter uses one key regardless of model.
    assert html =~ "OPENROUTER_API_KEY"
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

  test "enabling subscribes this device; disabling removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    subscription = %{
      "endpoint" => "https://push.example/xyz",
      "keys" => %{"p256dh" => "pkey", "auth" => "akey"}
    }

    render_hook(view, "enable_reminders", %{"subscription" => subscription})
    assert [_] = Push.list_subscriptions()

    render_hook(view, "disable_reminders", %{"endpoint" => "https://push.example/xyz"})
    assert Push.list_subscriptions() == []
  end

  test "device_status drives this device's on/off display", %{conn: conn} do
    {:ok, _} = Push.subscribe(%{endpoint: "https://push.example/known", p256dh: "p", auth: "a"})
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "device_status", %{"endpoint" => "https://push.example/known"})
    assert has_element?(view, "#reminders-panel [data-action=disable]")
    refute has_element?(view, "#reminders-panel [data-action=enable]")

    render_hook(view, "device_status", %{"endpoint" => nil})
    assert has_element?(view, "#reminders-panel [data-action=enable]")
    refute has_element?(view, "#reminders-panel [data-action=disable]")
  end

  test "test_notification reaches this device", %{conn: conn} do
    device = push_device(201)
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "test_notification", %{"endpoint" => device.endpoint})

    assert_push_event(view, "toast", %{kind: "info"})
  end

  test "test_notification pushes an error toast when this device isn't subscribed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "test_notification", %{})

    assert_push_event(view, "toast", %{kind: "error"})
  end
end
