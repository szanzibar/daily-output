defmodule DailyOutput.PromptCache do
  @moduledoc """
  Day-long cache for AI-generated journal prompts and conversation openers.

  Generating prompts is slow and non-deterministic, so we keep one set per
  (kind, languages, topics) for 24 hours. Navigating away and back, or re-opening
  the page, reuses the same set instead of paying for a fresh generation.

  Values are JSON-encoded lists of `%{"prompt" => ..., "translation" => ...}` (or
  `"opener"`) maps, stored in the `cache` table.
  """

  use Ecto.Schema
  import Ecto.Query

  alias DailyOutput.Repo

  @ttl_seconds 86_400

  schema "cache" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the cached list for the given parameters, or `nil` if absent/expired/corrupt."
  def get(kind, topics, target_language, native_language) do
    key = key(kind, topics, target_language, native_language)
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_seconds)

    with %{value: json} <-
           Repo.one(from(c in __MODULE__, where: c.key == ^key and c.updated_at >= ^cutoff)),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      list
    else
      _ -> nil
    end
  end

  @doc "Stores `list` for the given parameters and returns it unchanged."
  def put(kind, topics, target_language, native_language, list) when is_list(list) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    value = Jason.encode!(list)

    Repo.insert!(
      %__MODULE__{
        key: key(kind, topics, target_language, native_language),
        value: value,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: :key
    )

    list
  end

  defp key(kind, topics, target_language, native_language) do
    "#{kind}:#{target_language}:#{native_language}:#{:erlang.phash2(topics)}"
  end
end
