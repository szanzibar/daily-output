defmodule Sprachjournal.Repo do
  use Ecto.Repo,
    otp_app: :sprachjournal,
    adapter: Ecto.Adapters.SQLite3
end
