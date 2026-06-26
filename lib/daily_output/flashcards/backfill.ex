defmodule DailyOutput.Flashcards.Backfill do
  @moduledoc """
  TEMPORARY one-time startup backfill.

  On boot, if the flashcards table is empty but the user already has corrections, this
  generates cards from that history automatically (in the background). Ongoing corrections
  already create cards via the ingest hooks, so this is only needed once to seed the deck.

  Safe to delete entirely once it has run in your environment: remove this module and the
  `backfill_child/0` entry in `DailyOutput.Application`.
  """

  require Logger
  import Ecto.Query

  alias DailyOutput.{Flashcards, Repo, Settings}
  alias DailyOutput.Flashcards.Card
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Conversations.Message

  @doc """
  Runs the backfill synchronously **iff** it's enabled and needed (empty deck + existing
  corrections). Meant to be run from a `Task` child so it never blocks boot.
  """
  def maybe_run do
    if enabled?() and needed?(), do: run()
    :ok
  end

  defp enabled?, do: Application.get_env(:daily_output, :auto_backfill_flashcards, true)

  defp needed?, do: no_cards?() and has_corrections?()

  defp no_cards?, do: Repo.aggregate(Card, :count, :id) == 0

  defp has_corrections? do
    Repo.exists?(from(e in Entry, where: is_nil(e.deleted_at) and not is_nil(e.feedback))) or
      Repo.exists?(from(m in Message, where: m.role == "user" and not is_nil(m.feedback)))
  end

  defp run do
    config = Settings.get_config()
    sources = entry_sources() ++ message_sources()
    Logger.info("[flashcards] auto-backfill: seeding from #{length(sources)} corrected source(s)")

    created =
      Enum.reduce(sources, 0, fn {type, id, feedback}, acc ->
        case Flashcards.ingest_correction(type, id, feedback, config: config) do
          {:ok, n} ->
            acc + n

          {:error, reason} ->
            Logger.warning(
              "[flashcards] auto-backfill: #{type} ##{id} failed: #{inspect(reason)}"
            )

            acc
        end
      end)

    Logger.info("[flashcards] auto-backfill: created #{created} flashcard(s)")
  end

  defp entry_sources do
    Repo.all(
      from(e in Entry,
        where: is_nil(e.deleted_at) and not is_nil(e.feedback),
        order_by: [asc: e.inserted_at],
        select: {e.id, e.feedback}
      )
    )
    |> Enum.map(fn {id, feedback} -> {:entry, id, feedback} end)
  end

  defp message_sources do
    Repo.all(
      from(m in Message,
        where: m.role == "user" and not is_nil(m.feedback),
        order_by: [asc: m.inserted_at],
        select: {m.id, m.feedback}
      )
    )
    |> Enum.map(fn {id, feedback} -> {:message, id, feedback} end)
  end
end
