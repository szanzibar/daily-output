defmodule DailyOutputWeb.Locale do
  @moduledoc "Sets Gettext locale based on user settings."

  @supported_ui_locales ~w(en de)

  def on_mount(:set_locale, _params, _session, socket) do
    config = DailyOutput.Settings.get_config()

    locale =
      case config && config.ui_language do
        "auto" -> auto_locale(config)
        lang when lang in @supported_ui_locales -> lang
        _ -> "en"
      end

    Gettext.put_locale(DailyOutputWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp auto_locale(nil), do: "en"

  defp auto_locale(config) do
    level = config.language_level || "A1"
    target = config.target_language || "de"
    level_num = level_to_number(level)

    if level_num >= 3 and target in @supported_ui_locales do
      target
    else
      "en"
    end
  end

  defp level_to_number("B1"), do: 3
  defp level_to_number("B2"), do: 4
  defp level_to_number("C1"), do: 5
  defp level_to_number("C2"), do: 6
  defp level_to_number(_), do: 1
end
