defmodule DailyOutput.PushTest do
  use DailyOutput.DataCase

  alias DailyOutput.Push

  @sub %{endpoint: "https://push.example/abc", p256dh: "key1", auth: "auth1"}

  test "subscribe stores a device" do
    assert {:ok, sub} = Push.subscribe(@sub)
    assert sub.endpoint == @sub.endpoint
    assert [_] = Push.list_subscriptions()
  end

  test "subscribe upserts on the same endpoint instead of duplicating" do
    {:ok, _} = Push.subscribe(@sub)
    {:ok, _} = Push.subscribe(%{@sub | p256dh: "key2", auth: "auth2"})

    assert [only] = Push.list_subscriptions()
    assert only.p256dh == "key2"
    assert only.auth == "auth2"
  end

  test "delete_by_endpoint removes the device" do
    {:ok, _} = Push.subscribe(@sub)
    assert :ok = Push.delete_by_endpoint(@sub.endpoint)
    assert Push.list_subscriptions() == []
  end

  test "send_to_all is a no-op (returns 0) when VAPID keys are not configured" do
    {:ok, _} = Push.subscribe(@sub)
    refute Push.configured?()
    assert Push.send_to_all(%{title: "Hi", body: "there"}) == 0
  end

  test "any?/count reflect whether any device is subscribed" do
    refute Push.any?()
    assert Push.count() == 0

    {:ok, _} = Push.subscribe(@sub)

    assert Push.any?()
    assert Push.count() == 1
  end

  test "subscribed? is true only for a known endpoint" do
    refute Push.subscribed?(@sub.endpoint)
    refute Push.subscribed?(nil)

    {:ok, _} = Push.subscribe(@sub)

    assert Push.subscribed?(@sub.endpoint)
    refute Push.subscribed?("https://push.example/unknown")
  end

  test "send_to_endpoint is a no-op (returns 0) when VAPID keys are not configured" do
    {:ok, _} = Push.subscribe(@sub)
    refute Push.configured?()
    assert Push.send_to_endpoint(@sub.endpoint, %{title: "Hi", body: "there"}) == 0
    assert Push.send_to_endpoint(nil, %{title: "Hi"}) == 0
  end
end
