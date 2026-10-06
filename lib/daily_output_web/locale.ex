defmodule DailyOutputWeb.Locale do
  @moduledoc "Sets the Gettext locale and theme from the settings."

  alias DailyOutput.Settings

  def on_mount(:set_locale, _params, _session, socket) do
    config = Settings.get_config()
    locale = Settings.ui_locale(config)
    Gettext.put_locale(DailyOutputWeb.Gettext, locale)

    theme =
      case config.theme do
        "light" -> "brutalist-light"
        "dark" -> "brutalist-dark"
        _ -> nil
      end

    {:cont, Phoenix.Component.assign(socket, locale: locale, theme: theme)}
  end
end
