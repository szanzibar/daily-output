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

  describe "public_key_valid?/0" do
    test "false when unset" do
      refute Push.public_key_valid?()
    end

    test "true for a real 65-byte P-256 point, false for a 32-byte (private) key" do
      {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

      Application.put_env(
        :web_push_elixir,
        :vapid_public_key,
        Base.url_encode64(public_key, padding: false)
      )

      on_exit(fn -> Application.delete_env(:web_push_elixir, :vapid_public_key) end)
      assert Push.public_key_valid?()

      # A private key (32 bytes) is the classic "pasted the wrong one" mistake.
      Application.put_env(
        :web_push_elixir,
        :vapid_public_key,
        Base.url_encode64(private_key, padding: false)
      )

      refute Push.public_key_valid?()
    end
  end
end
