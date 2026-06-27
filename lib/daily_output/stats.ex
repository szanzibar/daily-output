defmodule DailyOutput.Stats do
  @moduledoc """
  Aggregates the feedback the app already produces into progress metrics — the
  "I'm actually improving" view.

  Corrections are marked `[[N:original||corrected]]`. From that we derive, uniformly across
  entries and conversations:

    * **words written** — the user's text with markers reduced to what they wrote
    * **corrections** — the number of correction markers

  Journal entries carry one `feedback["annotated_text"]`. Conversations are corrected
  per-message, so we sum each user message's own `feedback` (older conversations that
  predate per-message corrections fall back to the conversation-level blob).

  The headline metric is **corrections per 100 words by week** — when it trends down,
  you're getting better.
  """

  import Ecto.Query

  alias DailyOutput.{Clock, Repo}
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Conversations.Conversation
  alias DailyOutput.FocusTopics.FocusTopic
  alias DailyOutput.Stats.TimeLog

  @marker ~r/\[\[(\d+):([\s\S]*?)\]\]/

  # Sections we track time for.
  @time_sections ~w(entry conversation flashcards)

  @doc """
  One pass over history → everything the progress page needs:
  lifetime totals, a weekly error-rate trend, and a 7-day recap.
  """
  def overview(weeks \\ 8) do
    samples = samples()
    today = Clock.today()

    %{
      total_words: sum(samples, & &1.words),
      entries: Enum.count(samples, &(&1.type == :entry)),
      conversations: Enum.count(samples, &(&1.type == :conversation)),
      active_days: samples |> Enum.map(& &1.date) |> Enum.uniq() |> length(),
      focus_mastered: mastered_count(),
      trend: trend(samples, today, weeks),
      recap: recap(samples, today),
      total_time: total_time(),
      time_today: time_for_day(today),
      time_days: time_by_day(7)
    }
  end

  @doc "Corrections per 100 words across `text`, or nil when there are no words."
  def error_rate(text) do
    rate(correction_count(text), word_count(text))
  end

  # ── Time tracking ──────────────────────────────────────

  @doc """
  Adds `seconds` of active time to today's `section` total (upsert-incremented).
  Section must be one of #{inspect(@time_sections)}; anything else is ignored.
  """
  def track(section, seconds)
      when is_binary(section) and is_integer(seconds) and seconds > 0 and
             section in @time_sections do
    Repo.insert(
      %TimeLog{day: Clock.today(), section: section, seconds: seconds},
      on_conflict: from(t in TimeLog, update: [inc: [seconds: ^seconds]]),
      conflict_target: [:day, :section]
    )
  end

  def track(_section, _seconds), do: {:ok, :ignored}

  @doc "Today's time breakdown: `%{entry, conversation, flashcards, total}` (seconds)."
  def time_today, do: time_for_day(Clock.today())

  @doc "Time breakdown for a logical `date`."
  def time_for_day(%Date{} = date) do
    from(t in TimeLog, where: t.day == ^date, select: {t.section, t.seconds})
    |> Repo.all()
    |> shape_breakdown()
  end

  @doc "Per-day time breakdowns for the last `days` days (oldest → newest)."
  def time_by_day(days) do
    today = Clock.today()
    start = Date.add(today, -(days - 1))

    by_day =
      from(t in TimeLog, where: t.day >= ^start, select: {t.day, t.section, t.seconds})
      |> Repo.all()
      |> Enum.group_by(fn {day, _s, _sec} -> day end, fn {_d, s, sec} -> {s, sec} end)

    for date <- Date.range(start, today) do
      Map.merge(%{date: date}, shape_breakdown(Map.get(by_day, date, [])))
    end
  end

  @doc "All-time total tracked time in seconds."
  def total_time, do: Repo.aggregate(TimeLog, :sum, :seconds) || 0

  @doc "Formats a duration in seconds as a compact `1h 5m` / `12m` / `<1m` string."
  def format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds <= 0 -> "0m"
      seconds < 60 -> "<1m"
      true -> format_hm(div(seconds, 3600), div(rem(seconds, 3600), 60))
    end
  end

  defp format_hm(0, m), do: "#{m}m"
  defp format_hm(h, 0), do: "#{h}h"
  defp format_hm(h, m), do: "#{h}h #{m}m"

  defp shape_breakdown(section_seconds) do
    by_section = Map.new(section_seconds)

    %{
      entry: Map.get(by_section, "entry", 0),
      conversation: Map.get(by_section, "conversation", 0),
      flashcards: Map.get(by_section, "flashcards", 0),
      total: section_seconds |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    }
  end

  # ── internals ──────────────────────────────────────────

  defp samples do
    entry_rows() ++ conversation_rows()
  end

  defp entry_rows do
    from(r in Entry,
      where: is_nil(r.deleted_at) and not is_nil(r.feedback) and not is_nil(r.completed_at),
      select: {r.inserted_at, r.feedback}
    )
    |> Repo.all()
    |> Enum.map(fn {inserted_at, feedback} ->
      text = feedback["annotated_text"] || ""

      %{
        type: :entry,
        date: Clock.to_logical_date(inserted_at),
        words: word_count(text),
        corrections: correction_count(text)
      }
    end)
  end

  defp conversation_rows do
    from(c in Conversation,
      where: is_nil(c.deleted_at) and not is_nil(c.feedback) and not is_nil(c.completed_at),
      preload: [:messages]
    )
    |> Repo.all()
    |> Enum.map(fn convo ->
      {words, corrections} = conversation_counts(convo)

      %{
        type: :conversation,
        date: Clock.to_logical_date(convo.inserted_at),
        words: words,
        corrections: corrections
      }
    end)
  end

  # New conversations are corrected per-message: sum each user message's own feedback
  # (using its body when a message has no feedback). Conversations predating per-message
  # corrections fall back to the conversation-level annotated_text blob.
  defp conversation_counts(convo) do
    user_messages = Enum.filter(convo.messages, &(&1.role == "user"))
    legacy_text = (convo.feedback || %{})["annotated_text"] || ""

    cond do
      Enum.any?(user_messages, &is_map(&1.feedback)) ->
        Enum.reduce(user_messages, {0, 0}, fn msg, {words, corrections} ->
          text = (is_map(msg.feedback) && msg.feedback["annotated_text"]) || msg.body || ""
          {words + word_count(text), corrections + correction_count(text)}
        end)

      legacy_text != "" ->
        {word_count(legacy_text), correction_count(legacy_text)}

      true ->
        {sum(user_messages, &word_count(&1.body || "")), 0}
    end
  end

  # Weekly buckets of the last `weeks` rolling 7-day windows, oldest → newest.
  defp trend(samples, today, weeks) do
    for w <- (weeks - 1)..0//-1 do
      finish = Date.add(today, -7 * w)
      start = Date.add(finish, -6)
      window = Enum.filter(samples, &within?(&1.date, start, finish))
      words = sum(window, & &1.words)

      %{
        start: start,
        finish: finish,
        words: words,
        error_rate: rate(sum(window, & &1.corrections), words)
      }
    end
  end

  defp recap(samples, today) do
    start = Date.add(today, -6)
    window = Enum.filter(samples, &within?(&1.date, start, today))
    words = sum(window, & &1.words)

    %{
      start: start,
      finish: today,
      days_active: window |> Enum.map(& &1.date) |> Enum.uniq() |> length(),
      words: words,
      corrections: sum(window, & &1.corrections),
      error_rate: rate(sum(window, & &1.corrections), words),
      focus_mastered: mastered_count(since: start)
    }
  end

  defp mastered_count(opts \\ []) do
    query = from(t in FocusTopic, where: not is_nil(t.mastered_at))

    query =
      case Keyword.get(opts, :since) do
        nil -> query
        date -> from(t in query, where: t.mastered_at >= ^elem(Clock.day_range(date), 0))
      end

    Repo.aggregate(query, :count)
  end

  @doc false
  def word_count(text) do
    text
    |> strip_markers()
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  @doc false
  def correction_count(text) do
    @marker
    |> Regex.scan(text || "")
    |> Enum.count(fn [_, _id, inner] ->
      case String.split(inner, "||", parts: 2) do
        [orig, corr] -> orig != "" or corr != ""
        _ -> false
      end
    end)
  end

  # Replace each marker with the original (what the user wrote) for word counting.
  defp strip_markers(text) do
    Regex.replace(@marker, text || "", fn whole, _id, inner ->
      case String.split(inner, "||", parts: 2) do
        [orig, _corr] -> orig
        _ -> whole
      end
    end)
  end

  defp within?(date, start, finish) do
    Date.compare(date, start) != :lt and Date.compare(date, finish) != :gt
  end

  defp sum(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp rate(_corrections, 0), do: nil
  defp rate(corrections, words), do: Float.round(corrections * 100 / words, 1)
end
