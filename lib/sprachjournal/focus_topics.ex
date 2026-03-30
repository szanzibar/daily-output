defmodule Sprachjournal.FocusTopics do
  @moduledoc """
  Context for managing focus topics and daily challenge status.
  """

  import Ecto.Query
  alias Sprachjournal.Repo
  alias Sprachjournal.FocusTopics.FocusTopic
  alias Sprachjournal.Journal.Entry
  alias Sprachjournal.Conversations.Conversation

  # ── CRUD ─────────────────────────────────────────────

  def list_active_topics do
    FocusTopic
    |> where([t], is_nil(t.mastered_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def list_all_topics do
    FocusTopic
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def get_topic!(id), do: Repo.get!(FocusTopic, id)

  def create_topic(attrs) do
    source_text = attrs[:source_text] || attrs["source_text"]

    if source_text && source_text != "" do
      existing =
        Repo.one(
          from(t in FocusTopic,
            where: t.source_text == ^source_text and is_nil(t.mastered_at),
            limit: 1
          )
        )

      if existing do
        {:error, :duplicate}
      else
        %FocusTopic{}
        |> FocusTopic.changeset(attrs)
        |> Repo.insert()
      end
    else
      %FocusTopic{}
      |> FocusTopic.changeset(attrs)
      |> Repo.insert()
    end
  end

  def master_topic(%FocusTopic{} = topic) do
    topic
    |> Ecto.Changeset.change(%{mastered_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  def delete_topic(%FocusTopic{} = topic) do
    Repo.delete(topic)
  end

  @doc "Returns a MapSet of source_texts for active topics (used for duplicate detection on tip buttons)."
  def active_source_texts do
    FocusTopic
    |> where([t], is_nil(t.mastered_at))
    |> select([t], t.source_text)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def has_active_topics? do
    Repo.exists?(from(t in FocusTopic, where: is_nil(t.mastered_at)))
  end

  # ── Daily Challenge ──────────────────────────────────

  @doc """
  Check today's daily challenge status.
  Entry/conversation complete = has feedback AND (has focus_topic OR pool was empty at time of creation).
  For simplicity: complete = has feedback AND has focus_topic_id, OR has feedback AND no active topics exist.
  """
  def daily_challenge_status do
    {today_start, today_end} = today_range()
    has_pool = has_active_topics?()

    entry_complete =
      if has_pool do
        Repo.exists?(
          from(e in Entry,
            where:
              is_nil(e.deleted_at) and not is_nil(e.feedback) and
                not is_nil(e.focus_topic_id) and
                e.inserted_at >= ^today_start and e.inserted_at < ^today_end
          )
        )
      else
        Repo.exists?(
          from(e in Entry,
            where:
              is_nil(e.deleted_at) and not is_nil(e.feedback) and
                e.inserted_at >= ^today_start and e.inserted_at < ^today_end
          )
        )
      end

    conversation_complete =
      if has_pool do
        Repo.exists?(
          from(c in Conversation,
            where:
              is_nil(c.deleted_at) and not is_nil(c.feedback) and
                not is_nil(c.focus_topic_id) and
                c.inserted_at >= ^today_start and c.inserted_at < ^today_end
          )
        )
      else
        Repo.exists?(
          from(c in Conversation,
            where:
              is_nil(c.deleted_at) and not is_nil(c.feedback) and
                c.inserted_at >= ^today_start and c.inserted_at < ^today_end
          )
        )
      end

    %{
      entry: if(entry_complete, do: :complete, else: :none),
      conversation: if(conversation_complete, do: :complete, else: :none),
      all_done: entry_complete and conversation_complete
    }
  end

  @doc "Check if a specific date was fully completed."
  def day_completed?(date) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    entry_done =
      Repo.exists?(
        from(e in Entry,
          where:
            is_nil(e.deleted_at) and not is_nil(e.feedback) and
              e.inserted_at >= ^day_start and e.inserted_at < ^day_end
        )
      )

    convo_done =
      Repo.exists?(
        from(c in Conversation,
          where:
            is_nil(c.deleted_at) and not is_nil(c.feedback) and
              c.inserted_at >= ^day_start and c.inserted_at < ^day_end
        )
      )

    entry_done and convo_done
  end

  @doc "Count consecutive completed days ending today."
  def current_streak do
    count_streak(Date.utc_today(), 0)
  end

  defp count_streak(date, count) do
    if day_completed?(date) do
      count_streak(Date.add(date, -1), count + 1)
    else
      count
    end
  end

  defp today_range do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    today_end = Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    {today_start, today_end}
  end
end
