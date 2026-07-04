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

# The one model for everything (used by DailyOutput.AI.chat/2 when no per-purpose override
# applies — see :ai_model_overrides below, now empty): GLM 5.2. Its German is fluent and
# idiomatic (incl. Swiss dialect), and head-to-head on both the chat and journal correction
# paths (scripts/exp_corrections.exs, scripts/exp_journal.exs) it matches Sonnet's error recall
# at ~1/10th the cost. Both proofread paths (journal `proofread` + chat `proofread_message`)
# share one rewrite+diff pipeline: the model only rewrites the text and lists changes, and
# DailyOutput.AI.RewriteDiff builds the [[..]] markers in code, so a garbled marker (the old
# word-order-move failure) is impossible regardless of model. Needs ZAI_API_KEY set; override
# per environment with AI_MODEL (runtime.exs).
config :daily_output, :ai_model, "zai:glm-5.2"

# Per-purpose model routing (by the `:purpose` tag in DailyOutput.AI.chat/2) — the escape hatch
# to send one call site to a different model without changing the default. Empty: every purpose
# uses the default above. e.g. %{"proofread" => "anthropic:claude-sonnet-4-6"} would put journal
# proofread back on Sonnet (needs ANTHROPIC_API_KEY).
config :daily_output, :ai_model_overrides, %{}

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
