import Config

# Load .env file if it exists (dev/local convenience)
if config_env() != :test do
  Dotenvy.source!([".env", System.get_env()])

  # Both keys are optional so the app boots with whichever provider you've configured.
  config :daily_output, :anthropic_api_key, Dotenvy.env!("ANTHROPIC_API_KEY", :string, "")
  config :daily_output, :zai_api_key, Dotenvy.env!("ZAI_API_KEY", :string, "")

  # "provider:model" spec (e.g. "anthropic:claude-sonnet-4-6") overriding the default in
  # config.exs (zai:glm-5.2); blank = keep that default.
  case Dotenvy.env!("AI_MODEL", :string, "") do
    "" -> :ok
    spec -> config :daily_output, :ai_model, spec
  end

  # Web Push keys are generated and stored in the DB on first boot — see
  # `DailyOutput.Vapid`. Nothing to configure here.

  config :daily_output, default_timezone: Dotenvy.env!("DEFAULT_TIMEZONE", :string, "Etc/UTC")
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/daily_output start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :daily_output, DailyOutputWeb.Endpoint, server: true
end

config :daily_output, DailyOutputWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path = "/app/data/daily_output.db"

  config :daily_output, DailyOutput.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Start with bin/server to auto-generate one, or set SECRET_KEY_BASE manually.
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname served by your reverse proxy, for example: app.example.com
      """

  config :daily_output, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Identify this server to push services (RFC 8292 VAPID "sub"). In prod we use
  # the public host; dev/test keep the static default in config.exs.
  config :web_push_elixir, vapid_subject: "https://#{host}"

  config :daily_output, DailyOutputWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: ["https://#{host}"],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :daily_output, DailyOutputWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :daily_output, DailyOutputWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
