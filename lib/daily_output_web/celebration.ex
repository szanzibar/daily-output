defmodule DailyOutputWeb.Celebration do
  @moduledoc """
  Builds the payload the client `phx:celebrate` listener renders as brutalist confetti.
  """
  use Gettext, backend: DailyOutputWeb.Gettext

  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  @doc "Parses a `celebrate` token into a `push_event` payload (with localized copy), or `nil`."
  def event("day"), do: %{kind: "day", message: gettext("Day complete!")}
  def event(_), do: nil

  @doc """
  Pushes a `celebrate` event for the given token when the socket is connected and the
  token names a real celebration; otherwise returns the socket unchanged.
  """
  def maybe_push(socket, token) do
    with true <- connected?(socket),
         %{} = payload <- event(token) do
      push_event(socket, "celebrate", payload)
    else
      _ -> socket
    end
  end
end
