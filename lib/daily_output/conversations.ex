defmodule DailyOutput.Conversations do
  @moduledoc """
  Context for managing conversations. Follows the same patterns as Journal.
  """

  import Ecto.Query
  alias DailyOutput.Clock
  alias DailyOutput.Repo
  alias DailyOutput.Stats
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

  @doc """
  Copies a message into `conversation`, carrying over its per-message feedback verbatim.

  Used when branching a completed conversation into a new editable version: the corrections
  already earned on prior turns must travel with them, so the new version isn't a blank slate.
  """
  def copy_message(%Conversation{} = conversation, %Message{} = source) do
    with {:ok, message} <-
           add_message(conversation, %{role: source.role, body: source.body}) do
      if is_map(source.feedback) do
        # Carry the flashcard watermark forward too, so already-carded turns aren't re-carded
        # when the branched conversation is completed again.
        message
        |> Message.feedback_changeset(source.feedback)
        |> Ecto.Changeset.put_change(:flashcards_at, source.flashcards_at)
        |> Repo.update()
      else
        {:ok, message}
      end
    end
  end

  def complete_conversation(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Two-axis improvement signal for a finished conversation — the "did you stop repeating the
  same mistakes once they were flagged?" axis (pure, deterministic, no AI).

  Walks the user messages in order and, from each message's per-message corrections, derives:

    * `resolved_categories` — categories flagged once early that did NOT recur afterwards
    * `repeated_categories` — categories the student kept making across multiple messages
    * `early_rate` / `late_rate` — corrections per 100 words in the first vs. second half

  `messages` is the full message list (user + partner); only user messages count, and a
  message without feedback contributes its words but no corrections.
  """
  def mistake_analysis(messages) do
    user_messages = Enum.filter(messages, &(&1.role == "user"))
    n = length(user_messages)

    per_message =
      Enum.map(user_messages, fn msg ->
        annotations = message_annotations(msg)

        %{
          categories: annotations |> Enum.map(& &1["category"]) |> Enum.reject(&is_nil/1),
          corrections: length(annotations),
          words: Stats.word_count(message_text(msg))
        }
      end)

    # category → the message indices it appears in (a mistake repeated within one message
    # still counts as a single occurrence for the "across messages" signal).
    category_messages =
      per_message
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {%{categories: cats}, idx}, acc ->
        Enum.reduce(Enum.uniq(cats), acc, fn cat, acc2 ->
          Map.update(acc2, cat, [idx], &[idx | &1])
        end)
      end)

    resolved =
      for {cat, idxs} <- category_messages,
          length(idxs) == 1 and hd(idxs) < n - 1,
          do: cat

    repeated =
      for {cat, idxs} <- category_messages, length(idxs) >= 2, do: cat

    {early, late} = Enum.split(per_message, div(n, 2))

    %{
      "user_message_count" => n,
      "total_corrections" => sum_by(per_message, & &1.corrections),
      "by_category" => per_message |> Enum.flat_map(& &1.categories) |> Enum.frequencies(),
      "resolved_categories" => Enum.sort(resolved),
      "repeated_categories" => Enum.sort(repeated),
      "early_rate" => half_rate(early),
      "late_rate" => half_rate(late)
    }
  end

  defp half_rate(per_message) do
    words = sum_by(per_message, & &1.words)
    corrections = sum_by(per_message, & &1.corrections)
    if words == 0, do: nil, else: Float.round(corrections * 100 / words, 1)
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp message_annotations(%{feedback: %{"annotations" => anns}}) when is_list(anns), do: anns
  defp message_annotations(_), do: []

  defp message_text(%{feedback: %{"annotated_text" => at}}) when is_binary(at) and at != "",
    do: at

  defp message_text(%{body: body}) when is_binary(body), do: body
  defp message_text(_), do: ""

  def save_feedback(%Conversation{} = conversation, feedback) do
    normalized_feedback = Proofreader.normalize_feedback(feedback)

    conversation
    |> Conversation.changeset(%{feedback: normalized_feedback})
    |> Repo.update()
  end

  @doc "Stores per-message proofreading feedback on a single user message."
  def save_message_feedback(%Message{} = message, feedback) do
    normalized = Proofreader.normalize_message_feedback(feedback)

    message
    |> Message.feedback_changeset(normalized)
    |> Repo.update()
  end

  def save_message_feedback(message_id, feedback) when is_integer(message_id) do
    save_message_feedback(Repo.get!(Message, message_id), feedback)
  end

  def soft_delete_conversation(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # Minimum user exchanges that unlock finishing a conversation. `min_exchanges` (a
  # setting) stays the suggested *target*; this lower floor lets a warm-up still count
  # as the conversation task (one task keeps the streak).
  @warmup_exchanges 2

  @doc "Minimum user exchanges that unlock finishing a conversation."
  def warmup_exchanges, do: @warmup_exchanges

  @doc "Returns the latest conversation for today, if any."
  def get_today_conversation do
    {today_start, today_end} = Clock.day_range(Clock.today())

    Conversation
    |> not_deleted()
    |> where([c], c.inserted_at >= ^today_start and c.inserted_at < ^today_end)
    |> order_by([c], desc: c.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns all non-deleted conversations for the same date."
  def get_versions(%Conversation{} = conversation) do
    date = Clock.to_logical_date(conversation.inserted_at)
    {day_start, day_end} = Clock.day_range(date)

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
    {today_start, _} = Clock.day_range(Clock.today())

    convos =
      Conversation
      |> not_deleted()
      |> where([c], c.inserted_at >= ^cutoff and c.inserted_at < ^today_start)
      |> order_by([c], desc: c.inserted_at)
      |> Repo.all()

    convos
    |> Enum.group_by(fn c -> Clock.to_logical_date(c.inserted_at) end)
    |> Enum.map(fn {_date, [latest | _]} -> latest end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
