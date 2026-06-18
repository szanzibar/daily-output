defmodule DailyOutputWeb.Celebration do
  @moduledoc """
  Decides which celebration (if any) fires after a task is completed, and builds the
  payload the client `phx:celebrate` listener renders as brutalist confetti.

  A completed day (both tasks) beats a streak milestone — you only see one burst.
  """
  use Gettext, backend: DailyOutputWeb.Gettext

  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias DailyOutput.FocusTopics

  @doc """
  Token to append as `?celebrate=` on the post-completion redirect, or `nil`.

  Takes the *post-completion* day-complete flag and current streak count.
  """
  def after_completion(all_done?, streak_count) do
    cond do
      all_done? -> "day"
      FocusTopics.streak_milestone?(streak_count) -> "streak-#{streak_count}"
      true -> nil
    end
  end

  @doc "Parses a `celebrate` token into a `push_event` payload (with localized copy), or `nil`."
  def event("day"), do: %{kind: "day", message: gettext("Day complete!")}

  def event("streak-" <> count) do
    case Integer.parse(count) do
      {n, ""} -> %{kind: "streak", count: n, message: gettext("%{count}-day streak!", count: n)}
      _ -> nil
    end
  end

  def event(_), do: nil

  @doc """
  Pushes a `celebrate` event for the given token when the socket is connected and the
  token names a real celebration; otherwise returns the socket unchanged. The window
  listener in `app.js` turns the payload into brutalist confetti.
  """
  def maybe_push(socket, token) do
    with true <- connected?(socket),
         token when is_binary(token) <- token,
         %{} = payload <- event(token) do
      push_event(socket, "celebrate", payload)
    else
      _ -> socket
    end
  end
end
