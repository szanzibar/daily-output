defmodule DailyOutput.Vapid do
  @moduledoc """
  Self-managed VAPID keypair for Web Push.

  The keys browsers use to authenticate push are generated once on first boot and
  stored in the database — the same data volume as the SQLite file and
  `secret_key_base` — so a fresh `docker run` has working push with no manual key
  setup. There is no other way to provide keys: the DB is the single source.

  `ensure_keys/0` runs once at boot via this module's supervised child, which does
  its work in `start_link/0` and then returns `:ignore` so it leaves the tree.
  """

  import Ecto.Query
  require Logger

  alias DailyOutput.Repo
  alias DailyOutput.Vapid.Keypair

  @doc false
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  @doc false
  def start_link do
    ensure_keys()
    :ignore
  end

  @doc """
  Ensures VAPID keys are configured: loads the stored keypair, generating and
  persisting one if the DB has none yet. Sets the `:web_push_elixir` public/private
  keys used for sending. Returns `:ok`.
  """
  def ensure_keys do
    keypair = load_or_create()
    Application.put_env(:web_push_elixir, :vapid_public_key, keypair.public_key)
    Application.put_env(:web_push_elixir, :vapid_private_key, keypair.private_key)
    :ok
  end

  defp load_or_create do
    case Repo.one(from(k in Keypair, limit: 1)) do
      nil -> create()
      keypair -> keypair
    end
  end

  defp create do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, keypair} =
      %Keypair{}
      |> Keypair.changeset(%{
        public_key: Base.url_encode64(public_key, padding: false),
        private_key: Base.url_encode64(private_key, padding: false)
      })
      |> Repo.insert()

    Logger.info("Generated a VAPID keypair for Web Push (stored in the database).")
    keypair
  end
end
