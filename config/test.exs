import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :daily_output, DailyOutput.Repo,
  database: Path.expand("../daily_output_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :daily_output, DailyOutputWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/xD6yxGcMt2uKnXA1oFAmtgWR7UndlZm4oflvTu7oN2aFGFtepvSJMzuoN1wxgwR",
  server: false

# Don't run the reminder scheduler during tests, and don't auto-generate VAPID
# keys — the push tests assert on the unconfigured state.
config :daily_output, start_reminders: false, ensure_vapid: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
