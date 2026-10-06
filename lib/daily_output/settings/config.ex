defmodule DailyOutput.Settings.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :target_language, :string, default: "de"
    field :native_language, :string, default: "en"
    field :language_level, :string, default: "B2"
    # Free text the AI reads to personalize prompts: interests, goals, context.
    field :about_you, :string, default: ""
    field :ui_language, :string, default: "auto"
    field :theme, :string, default: "auto"
    # How AI calls are routed: "direct" (each vendor's own API) or "openrouter".
    field :ai_provider, :string, default: "direct"
    # Which model runs everything: "gpt-6.1-sol" or "gpt-6-luna". DailyOutput.AI.spec_for/2
    # maps the (ai_provider, ai_model) pair to a concrete provider + model id.
    field :ai_model, :string, default: "gpt-6.1-sol"
    field :timezone, :string
    field :reminder_time, :time, default: ~T[20:00:00]
    field :last_reminder_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :target_language,
      :native_language,
      :language_level,
      :about_you,
      :ui_language,
      :theme,
      :ai_provider,
      :ai_model,
      :timezone,
      :reminder_time,
      :last_reminder_on
    ])
    |> validate_required([:target_language, :native_language])
    |> validate_inclusion(:ui_language, ~w(auto en de))
    |> validate_inclusion(:theme, ~w(auto light dark))
    |> validate_inclusion(:ai_provider, ~w(direct openrouter))
    |> validate_inclusion(:ai_model, ~w(gpt-6.1-sol gpt-6-luna))
  end
end
