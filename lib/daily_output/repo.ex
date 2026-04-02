defmodule DailyOutput.Repo do
  use Ecto.Repo,
    otp_app: :daily_output,
    adapter: Ecto.Adapters.SQLite3
end
