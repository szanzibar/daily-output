# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :daily_output,
  ecto_repos: [DailyOutput.Repo],
  generators: [timestamp_type: :utc_datetime]

# Per-purpose model routing (by the `:purpose` tag in DailyOutput.AI.chat/2). Free-form
# generation goes to cheaper GLM — its German is fluent and idiomatic (incl. Swiss dialect).
# Chat corrections (proofread_message) also run on GLM now: the corrector no longer asks the
# model to hand-place [[..]] markers (which GLM garbled on word-order moves) — it just rewrites
# the message and lists changes, and DailyOutput.AI.RewriteDiff builds the markers in code, so
# GLM's output is clean and ~1/3 the tokens. The journal `proofread` uses the same rewrite+diff
# format but stays on Sonnet (higher-stakes, once-daily; global `:ai_model` default). Needs
# ZAI_API_KEY set.
config :daily_output, :ai_model_overrides, %{
  "flashcards" => "zai:glm-5.2",
  "prompts" => "zai:glm-5.2",
  "openers" => "zai:glm-5.2",
  "conversation" => "zai:glm-5.2",
  "proofread_message" => "zai:glm-5.2"
}

# Configure the endpoint
config :daily_output, DailyOutputWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DailyOutputWeb.ErrorHTML, json: DailyOutputWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DailyOutput.PubSub,
  live_view: [signing_salt: "cnBQHVaE"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  daily_output: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  daily_output: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Time zone database for local-time math (reminders, day boundaries)
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Web Push. The VAPID keypair is generated and stored in the DB on first boot
# (see `DailyOutput.Vapid`). The contact subject (RFC 8292 "sub") defaults to this
# placeholder; in prod runtime.exs derives it from PHX_HOST as https://<host>.
config :web_push_elixir, vapid_subject: "mailto:admin@example.com"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
