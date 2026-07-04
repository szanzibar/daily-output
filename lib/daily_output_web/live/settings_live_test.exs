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

  test "AI section saves model/provider and its key status follows the choice", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    # Default direct + GLM → the status watches ZAI_API_KEY.
    assert html =~ "ZAI_API_KEY"

    html =
      view
      |> form("#settings-form", config: %{ai_provider: "openrouter", ai_model: "sonnet-4-6"})
      |> render_change()

    config = Settings.get_config()
    assert config.ai_provider == "openrouter"
    assert config.ai_model == "sonnet-4-6"
    # OpenRouter uses one key regardless of model.
    assert html =~ "OPENROUTER_API_KEY"

    html =
      view
      |> form("#settings-form", config: %{ai_provider: "direct", ai_model: "sonnet-4-6"})
      |> render_change()

    # Direct + Sonnet → Anthropic's own API.
    assert html =~ "ANTHROPIC_API_KEY"
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
    # The reminders panel only renders when push is configured.
    {public_key, _} = :crypto.generate_key(:ecdh, :prime256v1)

    Application.put_env(
      :web_push_elixir,
      :vapid_public_key,
      Base.url_encode64(public_key, padding: false)
    )

    on_exit(fn -> Application.delete_env(:web_push_elixir, :vapid_public_key) end)

    {:ok, _} = Push.subscribe(%{endpoint: "https://push.example/known", p256dh: "p", auth: "a"})
    {:ok, view, _html} = live(conn, ~p"/settings")

    # Assert on the (untranslated) data-action attributes, not button text —
    # the page renders in the config's UI language, which defaults to German.
    html = render_hook(view, "device_status", %{"endpoint" => "https://push.example/known"})
    assert html =~ ~s(data-action="disable")
    refute html =~ ~s(data-action="enable")

    html = render_hook(view, "device_status", %{"endpoint" => nil})
    assert html =~ ~s(data-action="enable")
    refute html =~ ~s(data-action="disable")
  end

  test "test_notification pushes an error toast when this device isn't subscribed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "test_notification", %{})

    assert_push_event(view, "toast", %{kind: "error"})
  end
end
