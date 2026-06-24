defmodule DailyOutput.VapidTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Push, Repo, Vapid}
  alias DailyOutput.Vapid.Keypair

  setup do
    # ensure_keys/0 mutates global app env; start clean and restore afterwards.
    Application.delete_env(:web_push_elixir, :vapid_public_key)
    Application.delete_env(:web_push_elixir, :vapid_private_key)

    on_exit(fn ->
      Application.delete_env(:web_push_elixir, :vapid_public_key)
      Application.delete_env(:web_push_elixir, :vapid_private_key)
    end)
  end

  test "generates and persists a keypair on first run, then push is configured" do
    assert Repo.aggregate(Keypair, :count) == 0

    assert :ok = Vapid.ensure_keys()

    assert Repo.aggregate(Keypair, :count) == 1
    assert Push.configured?()
  end

  test "reuses the stored keypair instead of generating a new one" do
    :ok = Vapid.ensure_keys()
    first = Push.vapid_public_key()

    # Drop the in-memory config so ensure_keys/0 must reload from the DB.
    Application.delete_env(:web_push_elixir, :vapid_public_key)
    :ok = Vapid.ensure_keys()

    assert Push.vapid_public_key() == first
    assert Repo.aggregate(Keypair, :count) == 1
  end
end
