defmodule DailyOutput.Settings do
  @moduledoc """
  Context for managing user settings.
  Single-row configuration table.
  """

  import Ecto.Query
  alias DailyOutput.Repo
  alias DailyOutput.Settings.Config

  def get_config do
    Repo.one(from(c in Config, limit: 1)) || %Config{}
  end

  def ensure_config do
    case Repo.one(from(c in Config, limit: 1)) do
      nil -> create_config(%{})
      config -> {:ok, config}
    end
  end

  defp create_config(attrs) do
    %Config{}
    |> Config.changeset(attrs)
    |> Repo.insert()
  end

  def update_config(%Config{} = config, attrs) do
    config
    |> Config.changeset(attrs)
    |> Repo.update()
  end

  def change_config(%Config{} = config, attrs \\ %{}) do
    Config.changeset(config, attrs)
  end

  @doc """
  The UI language for `config`. "auto" is the target language from B1 up, when the UI has it,
  and English otherwise. The pages and the push reminders both read it here.
  """
  def ui_locale(%Config{ui_language: "auto"} = config) do
    if config.language_level in ~w(B1 B2 C1 C2) and config.target_language in ~w(en de),
      do: config.target_language,
      else: "en"
  end

  def ui_locale(%Config{ui_language: locale}), do: locale
end
