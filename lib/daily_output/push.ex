defmodule DailyOutput.Push do
  @moduledoc """
  Web Push subscriptions and delivery.

  Stores one row per device and sends notifications via `WebPushElixir`. Subscriptions
  that the push service reports as gone (HTTP 404/410) are pruned automatically.
  Delivery is a no-op unless VAPID keys are configured.
  """

  import Ecto.Query
  require Logger

  alias DailyOutput.Repo
  alias DailyOutput.Push.Subscription

  @doc "The public VAPID key browsers need as `applicationServerKey` (\"\" if unset)."
  def vapid_public_key, do: Application.get_env(:web_push_elixir, :vapid_public_key) || ""

  @doc "True when VAPID keys are configured, i.e. push can actually be sent."
  def configured?, do: vapid_public_key() != ""

  @doc "Stores (or refreshes) a device subscription, keyed by its endpoint."
  def subscribe(attrs) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def list_subscriptions, do: Repo.all(Subscription)

  @doc "Number of subscribed devices."
  def count, do: Repo.aggregate(Subscription, :count)

  @doc "True when at least one device is subscribed (i.e. reminders have somewhere to go)."
  def any?, do: Repo.exists?(Subscription)

  @doc "True when `endpoint` belongs to a known (subscribed) device."
  def subscribed?(endpoint) when is_binary(endpoint),
    do: Repo.exists?(from(s in Subscription, where: s.endpoint == ^endpoint))

  def subscribed?(_), do: false

  def delete_by_endpoint(endpoint) do
    Repo.delete_all(from(s in Subscription, where: s.endpoint == ^endpoint))
    :ok
  end

  @doc """
  Sends `payload` (a map; encoded to JSON for the service worker) to every subscription.
  Prunes expired subscriptions. Returns the number of successful sends.
  """
  def send_to_all(payload) when is_map(payload) do
    if configured?() do
      message = Jason.encode!(payload)
      list_subscriptions() |> Enum.count(&(send_one(&1, message) == :ok))
    else
      Logger.info("Push not configured (no VAPID keys); skipping send.")
      0
    end
  end

  @doc """
  Sends `payload` to the single device identified by `endpoint`. Used for
  per-device test notifications. Returns 1 on success, 0 otherwise.
  """
  def send_to_endpoint(endpoint, payload) when is_binary(endpoint) and is_map(payload) do
    with true <- configured?(),
         sub when not is_nil(sub) <-
           Repo.one(from(s in Subscription, where: s.endpoint == ^endpoint)),
         :ok <- send_one(sub, Jason.encode!(payload)) do
      1
    else
      _ -> 0
    end
  end

  def send_to_endpoint(_endpoint, _payload), do: 0

  defp send_one(subscription, message) do
    body =
      Jason.encode!(%{
        "endpoint" => subscription.endpoint,
        "keys" => %{"p256dh" => subscription.p256dh, "auth" => subscription.auth}
      })

    case WebPushElixir.send_notification(body, message) do
      {:ok, _} ->
        :ok

      {:error, :expired} ->
        delete_by_endpoint(subscription.endpoint)
        :error

      other ->
        Logger.warning("Push send failed: #{inspect(other)}")
        :error
    end
  end
end
