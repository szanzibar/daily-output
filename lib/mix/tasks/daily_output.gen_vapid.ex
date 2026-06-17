defmodule Mix.Tasks.DailyOutput.GenVapid do
  @shortdoc "Generate VAPID keys as ready-to-paste .env lines"

  @moduledoc """
  Generates a VAPID keypair for Web Push and prints it as `.env` lines.

      $ mix daily_output.gen_vapid

  Copy the three lines into your `.env` (don't swap public/private!) and restart.
  The public key is the 65-byte P-256 point browsers expect as `applicationServerKey`.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    IO.puts("")
    IO.puts("VAPID_PUBLIC_KEY=" <> Base.url_encode64(public_key, padding: false))
    IO.puts("VAPID_PRIVATE_KEY=" <> Base.url_encode64(private_key, padding: false))
    IO.puts("VAPID_SUBJECT=mailto:you@example.com")
    IO.puts("")
  end
end
