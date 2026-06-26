defmodule Mix.Tasks.DailyOutput.BackfillFlashcards do
  @shortdoc "Generates flashcards from all existing corrections in the database"

  @moduledoc """
  One-time backfill: walk every journal entry and conversation message that already has
  correction feedback, and turn each into spaced-repetition flashcards.

  Cards land in the `new` state and are introduced gradually by the per-day target, so a
  large backlog never floods a single study session. Capitalization-only corrections are
  skipped, and duplicates are deduped, so the task is safe to re-run.

      mix daily_output.backfill_flashcards
  """

  use Mix.Task

  import Ecto.Query

  alias DailyOutput.{Flashcards, Repo, Settings}
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Conversations.Message

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    config = Settings.get_config()

    sources =
      entry_sources() ++ message_sources()

    total = length(sources)
    IO.puts("Backfilling flashcards from #{total} corrected source(s)...")

    {created, processed} =
      sources
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {{type, id, feedback}, idx}, {created, processed} ->
        count =
          case Flashcards.ingest_correction(type, id, feedback, config: config) do
            {:ok, n} ->
              n

            {:error, reason} ->
              IO.puts("  ! #{type} ##{id} failed: #{inspect(reason)}")
              0
          end

        if rem(idx, 10) == 0 or idx == total do
          IO.puts("  [#{idx}/#{total}] cards so far: #{created + count}")
        end

        {created + count, processed + 1}
      end)

    IO.puts("Done. Processed #{processed} source(s), created #{created} new flashcard(s).")
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
