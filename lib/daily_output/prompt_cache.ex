defmodule DailyOutput.PromptCache do
  @moduledoc """
  Day-long cache for AI-generated journal prompts and conversation openers.

  Generating prompts is slow and non-deterministic, so we keep one set per
  (kind, languages, topics) for 24 hours. Navigating away and back, or re-opening
  the page, reuses the same set instead of paying for a fresh generation.

  Values are JSON-encoded lists of `%{"prompt" => ..., "translation" => ...}` (or
  `"opener"`) maps, stored in the shared `DailyOutput.Cache` table.
  """

  alias DailyOutput.Cache

  @ttl_seconds 86_400

  @doc "Returns the cached list for the given parameters, or `nil` if absent/expired/corrupt."
  def get(kind, topics, target_language, native_language) do
    case Cache.get(key(kind, topics, target_language, native_language), @ttl_seconds) do
      nil ->
        nil

      json ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> nil
        end
    end
  end

  @doc "Stores `list` for the given parameters and returns it unchanged."
  def put(kind, topics, target_language, native_language, list) when is_list(list) do
    Cache.put(key(kind, topics, target_language, native_language), Jason.encode!(list))
    list
  end

  defp key(kind, topics, target_language, native_language) do
    "#{kind}:#{target_language}:#{native_language}:#{:erlang.phash2(topics)}"
  end
end
