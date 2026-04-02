defmodule DailyOutput.Cache do
  @moduledoc """
  Simple key-value cache backed by SQLite.
  Used to avoid unnecessary API calls (e.g., model discovery).
  """

  use Ecto.Schema
  import Ecto.Query
  alias DailyOutput.Repo

  schema "cache" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  def get(key, max_age_seconds \\ 86400) do
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_seconds)

    case Repo.one(from(c in __MODULE__, where: c.key == ^key and c.updated_at >= ^cutoff)) do
      nil -> nil
      entry -> entry.value
    end
  end

  def put(key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.one(from(c in __MODULE__, where: c.key == ^key)) do
      nil ->
        %__MODULE__{key: key, value: value, inserted_at: now, updated_at: now}
        |> Repo.insert!()

      existing ->
        existing
        |> Ecto.Changeset.change(%{value: value, updated_at: now})
        |> Repo.update!()
    end

    value
  end
end
