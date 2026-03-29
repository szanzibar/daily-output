defmodule Sprachjournal.Practice do
  @moduledoc """
  Shared logic for practice mode: text extraction and character comparison.
  """

  alias Sprachjournal.Repo
  alias Sprachjournal.Journal.Entry
  alias Sprachjournal.Conversations.Conversation

  @marker_regex ~r/\[\[(\d+):([\s\S]*?)\]\]/

  @doc """
  Extract the corrected text from annotated_text by replacing
  each [[id:orig||corrected]] marker with just the corrected value.
  """
  def extract_corrected_text(nil), do: ""
  def extract_corrected_text(""), do: ""

  def extract_corrected_text(annotated_text) do
    Regex.replace(@marker_regex, annotated_text, fn _full, _id, inner ->
      case String.split(inner, "||", parts: 2) do
        [_orig, corrected] -> corrected
        _ -> inner
      end
    end)
    |> String.trim()
  end

  @doc """
  Extract corrected texts for a conversation (split by ---MSG_BREAK---).
  Returns a list of corrected user message strings.
  """
  def extract_conversation_texts(nil), do: []
  def extract_conversation_texts(""), do: []

  def extract_conversation_texts(annotated_text) do
    annotated_text
    |> String.split("---MSG_BREAK---")
    |> Enum.map(&extract_corrected_text(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Compare typed text against target character by character.
  Returns a list of {char, :correct | :wrong} tuples for typed portion,
  plus the remaining untyped target text.
  """
  def compare_chars(typed, target) do
    typed_chars = String.graphemes(typed)
    target_chars = String.graphemes(target)

    compared =
      typed_chars
      |> Enum.with_index()
      |> Enum.map(fn {char, idx} ->
        target_char = Enum.at(target_chars, idx)

        if char == target_char do
          {char, :correct}
        else
          {char, :wrong}
        end
      end)

    remaining = Enum.drop(target_chars, length(typed_chars)) |> Enum.join()

    completed =
      length(typed_chars) >= length(target_chars) and
        Enum.all?(compared, fn {_, s} -> s == :correct end)

    %{
      compared: compared,
      remaining: remaining,
      progress: min(length(typed_chars), length(target_chars)),
      total: length(target_chars),
      completed: completed
    }
  end

  @doc "Mark an entry as practiced."
  def mark_entry_practiced(%Entry{} = entry) do
    entry
    |> Ecto.Changeset.change(%{practiced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc "Mark a conversation as practiced."
  def mark_conversation_practiced(%Conversation{} = conversation) do
    conversation
    |> Ecto.Changeset.change(%{practiced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc """
  Check today's daily challenge status.
  Each task (entry, conversation) has two stages: written (feedback) and practiced.
  Without practice enabled, written = complete. With practice, written = half, practiced = full.
  Returns a map with task statuses and overall progress.
  """
  def daily_challenge_status(practice_enabled \\ true) do
    import Ecto.Query

    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    today_end = Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    entry_written =
      Repo.exists?(
        from(e in Entry,
          where:
            is_nil(e.deleted_at) and not is_nil(e.feedback) and
              e.inserted_at >= ^today_start and e.inserted_at < ^today_end
        )
      )

    entry_practiced =
      Repo.exists?(
        from(e in Entry,
          where:
            is_nil(e.deleted_at) and not is_nil(e.practiced_at) and
              e.inserted_at >= ^today_start and e.inserted_at < ^today_end
        )
      )

    conversation_written =
      Repo.exists?(
        from(c in Conversation,
          where:
            is_nil(c.deleted_at) and not is_nil(c.feedback) and
              c.inserted_at >= ^today_start and c.inserted_at < ^today_end
        )
      )

    conversation_practiced =
      Repo.exists?(
        from(c in Conversation,
          where:
            is_nil(c.deleted_at) and not is_nil(c.practiced_at) and
              c.inserted_at >= ^today_start and c.inserted_at < ^today_end
        )
      )

    entry_status =
      cond do
        !practice_enabled and entry_written -> :complete
        entry_practiced -> :complete
        entry_written -> :half
        true -> :none
      end

    conversation_status =
      cond do
        !practice_enabled and conversation_written -> :complete
        conversation_practiced -> :complete
        conversation_written -> :half
        true -> :none
      end

    all_done = entry_status == :complete and conversation_status == :complete

    %{
      entry: entry_status,
      conversation: conversation_status,
      practice_enabled: practice_enabled,
      all_done: all_done
    }
  end

  @doc """
  Check if a specific date was fully completed (both entry + conversation done).
  """
  def day_completed?(date, practice_enabled) do
    import Ecto.Query

    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    entry_done =
      if practice_enabled do
        Repo.exists?(
          from(e in Entry,
            where:
              is_nil(e.deleted_at) and not is_nil(e.practiced_at) and
                e.inserted_at >= ^day_start and e.inserted_at < ^day_end
          )
        )
      else
        Repo.exists?(
          from(e in Entry,
            where:
              is_nil(e.deleted_at) and not is_nil(e.feedback) and
                e.inserted_at >= ^day_start and e.inserted_at < ^day_end
          )
        )
      end

    convo_done =
      if practice_enabled do
        Repo.exists?(
          from(c in Conversation,
            where:
              is_nil(c.deleted_at) and not is_nil(c.practiced_at) and
                c.inserted_at >= ^day_start and c.inserted_at < ^day_end
          )
        )
      else
        Repo.exists?(
          from(c in Conversation,
            where:
              is_nil(c.deleted_at) and not is_nil(c.feedback) and
                c.inserted_at >= ^day_start and c.inserted_at < ^day_end
          )
        )
      end

    entry_done and convo_done
  end

  @doc """
  Count consecutive days (ending today) where both tasks were fully completed.
  """
  def current_streak(practice_enabled \\ true) do
    count_streak(Date.utc_today(), practice_enabled, 0)
  end

  defp count_streak(date, practice_enabled, count) do
    if day_completed?(date, practice_enabled) do
      count_streak(Date.add(date, -1), practice_enabled, count + 1)
    else
      count
    end
  end
end
