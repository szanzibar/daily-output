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

  @doc "True when VAPID keys are configured, i.e. push can actually be sent."
  def configured? do
    key = Application.get_env(:web_push_elixir, :vapid_public_key)
    is_binary(key) and key != ""
  end

  @doc """
  True when the configured public key is a valid 65-byte P-256 point — what browsers
  require as `applicationServerKey`. Catches the common "pasted the private key" mistake.
  """
  def public_key_valid? do
    case Application.get_env(:web_push_elixir, :vapid_public_key) do
      key when is_binary(key) and key != "" ->
        match?({:ok, <<4, _::binary-size(64)>>}, Base.url_decode64(key, padding: false))

      _ ->
        false
    end
  end

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
