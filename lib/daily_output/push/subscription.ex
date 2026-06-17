defmodule DailyOutput.Push.Subscription do
  @moduledoc "A device's Web Push subscription (one row per browser/device)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> unique_constraint(:endpoint)
  end
end
