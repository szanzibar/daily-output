defmodule DailyOutput.Conversations do
  @moduledoc """
  Context for managing conversations. Follows the same patterns as Journal.
  """

  import Ecto.Query
  alias DailyOutput.Repo
  alias DailyOutput.AI.Proofreader
  alias DailyOutput.Conversations.{Conversation, Message}

  defp not_deleted(query) do
    from(c in query, where: is_nil(c.deleted_at))
  end

  def get_conversation!(id) do
    conversation =
      Conversation
      |> not_deleted()
      |> Repo.get!(id)
      |> Repo.preload(:messages)

    %{conversation | feedback: Proofreader.normalize_feedback(conversation.feedback)}
  end

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def add_message(%Conversation{} = conversation, attrs) do
    %Message{}
    |> Message.changeset(Map.put(attrs, :conversation_id, conversation.id))
    |> Repo.insert()
  end

  def list_messages(%Conversation{} = conversation) do
    from(m in Message,
      where: m.conversation_id == ^conversation.id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  def complete_conversation(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def save_feedback(%Conversation{} = conversation, feedback) do
    normalized_feedback = Proofreader.normalize_feedback(feedback)

    conversation
    |> Conversation.changeset(%{feedback: normalized_feedback})
    |> Repo.update()
  end

  def soft_delete_conversation(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def user_message_count(%Conversation{} = conversation) do
    from(m in Message,
      where: m.conversation_id == ^conversation.id and m.role == "user"
    )
    |> Repo.aggregate(:count)
  end

  def get_today_conversations do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    today_end = Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Conversation
    |> not_deleted()
    |> where([c], c.inserted_at >= ^today_start and c.inserted_at < ^today_end)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc "Returns the latest conversation for today, if any."
  def get_today_conversation do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    today_end = Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Conversation
    |> not_deleted()
    |> where([c], c.inserted_at >= ^today_start and c.inserted_at < ^today_end)
    |> order_by([c], desc: c.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns all non-deleted conversations for the same date."
  def get_versions(%Conversation{} = conversation) do
    date = DateTime.to_date(conversation.inserted_at)
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Conversation
    |> not_deleted()
    |> where([c], c.inserted_at >= ^day_start and c.inserted_at < ^day_end)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  def version_info(%Conversation{} = conversation) do
    versions = get_versions(conversation)
    total = length(versions)
    chronological = Enum.reverse(versions)
    idx = Enum.find_index(chronological, &(&1.id == conversation.id))
    {(idx || 0) + 1, total}
  end

  @doc "Returns recent conversations (latest per day, excluding today) for the home page."
  def list_recent_conversations(days \\ 14) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400)
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    convos =
      Conversation
      |> not_deleted()
      |> where([c], c.inserted_at >= ^cutoff and c.inserted_at < ^today_start)
      |> order_by([c], desc: c.inserted_at)
      |> Repo.all()

    convos
    |> Enum.group_by(fn c -> DateTime.to_date(c.inserted_at) end)
    |> Enum.map(fn {_date, [latest | _]} -> latest end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
