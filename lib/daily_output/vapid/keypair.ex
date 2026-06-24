defmodule DailyOutput.Vapid.Keypair do
  @moduledoc "The app's self-managed VAPID keypair (single row, base64url-encoded)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "vapid_keys" do
    field :public_key, :string
    field :private_key, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(keypair, attrs) do
    keypair
    |> cast(attrs, [:public_key, :private_key])
    |> validate_required([:public_key, :private_key])
  end
end
