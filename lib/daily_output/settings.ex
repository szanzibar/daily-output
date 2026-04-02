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

  def get_config! do
    Repo.one!(from(c in Config, limit: 1))
  end

  def ensure_config do
    case Repo.one(from(c in Config, limit: 1)) do
      nil -> create_config(%{})
      config -> {:ok, config}
    end
  end

  def create_config(attrs) do
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
end
