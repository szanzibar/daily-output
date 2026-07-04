defmodule DailyOutput.Settings.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :timer_minutes, :integer, default: 5
    field :target_language, :string, default: "de"
    field :native_language, :string, default: "en"
    field :topics, {:array, :string}, default: []
    field :language_level, :string, default: "B2"
    field :prompt_context, :string, default: ""
    field :min_exchanges, :integer, default: 5
    field :flashcards_per_day, :integer, default: 15
    field :ui_language, :string, default: "auto"
    field :timezone, :string
    field :reminder_time, :time, default: ~T[20:00:00]
    field :last_reminder_on, :date
    field :theme, :string, default: "auto"
    # How AI calls are routed: "direct" (each vendor's own API) or "openrouter".
    field :ai_provider, :string, default: "direct"
    # Which model runs everything: "glm-5.2" or "sonnet-4-6". DailyOutput.AI maps the
    # (ai_provider, ai_model) pair to a concrete provider + model id.
    field :ai_model, :string, default: "glm-5.2"

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :timer_minutes,
      :target_language,
      :native_language,
      :topics,
      :language_level,
      :prompt_context,
      :min_exchanges,
      :flashcards_per_day,
      :ui_language,
      :timezone,
      :reminder_time,
      :last_reminder_on,
      :theme,
      :ai_provider,
      :ai_model
    ])
    |> validate_required([:timer_minutes, :target_language, :native_language])
    |> validate_number(:timer_minutes, greater_than: 0, less_than_or_equal_to: 60)
    |> validate_number(:flashcards_per_day, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_inclusion(:ui_language, ~w(auto en de))
    |> validate_inclusion(:theme, ~w(auto light dark))
    |> validate_inclusion(:ai_provider, ~w(direct openrouter))
    |> validate_inclusion(:ai_model, ~w(glm-5.2 sonnet-4-6))
  end
end
