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
  alias DailyOutput.Stats.{ApiUsage, TimeLog}

  # Current markers are [[before||after||type||explanation]]; older stored entries use the
  # legacy [[N:before||after]] (with a numeric id). One capture grabs the inner of either,
  # and marker_before_after/1 strips the legacy id so both count the same way.
  @marker ~r/\[\[([\s\S]*?)\]\]/

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
      time_days: time_by_day(7),
      usage_total: usage_total(),
      usage_today: usage_today(),
      usage_week: usage_since(Date.add(today, -6)),
      usage_days: usage_by_day(7),
      usage_by_purpose: usage_by_purpose()
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

  # ── API cost tracking ──────────────────────────────────

  # Approximate USD per 1,000,000 tokens, by model tier. Cache reads bill at ~0.1x
  # input, cache writes (5-minute TTL) at ~1.25x input. The app uses the latest
  # Sonnet (see DailyOutput.AI), so "sonnet" is the default tier.
  @pricing %{
    "opus" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "sonnet" => %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
    "haiku" => %{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25}
  }
  @default_tier "sonnet"

  @doc """
  Records one API call's token usage from the raw Anthropix `response`, tagged with
  `purpose`. Tolerant: a response without a `"usage"` map is ignored, so this never
  breaks the calling AI flow.
  """
  def record_usage(purpose, %{"usage" => usage} = response) when is_map(usage) do
    %ApiUsage{
      purpose: to_string(purpose || "other"),
      model: response["model"] || "unknown",
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: usage["cache_read_input_tokens"] || 0,
      cache_creation_tokens: usage["cache_creation_input_tokens"] || 0
    }
    |> Repo.insert()
  end

  def record_usage(_purpose, _response), do: {:ok, :ignored}

  @doc "Lifetime API spend: `%{cost, input_tokens, output_tokens, calls}` (cost in USD)."
  def usage_total, do: aggregate_cost(from(u in ApiUsage))

  @doc "Today's API spend (same shape as `usage_total/0`)."
  def usage_today, do: usage_for_day(Clock.today())

  defp usage_for_day(%Date{} = date) do
    {start, finish} = Clock.day_range(date)

    aggregate_cost(
      from(u in ApiUsage, where: u.inserted_at >= ^start and u.inserted_at <= ^finish)
    )
  end

  defp usage_since(%Date{} = start_date) do
    {start, _finish} = Clock.day_range(start_date)
    aggregate_cost(from(u in ApiUsage, where: u.inserted_at >= ^start))
  end

  # Sum tokens grouped by model, then price each model group with its own rates.
  defp aggregate_cost(query) do
    from(u in query,
      group_by: u.model,
      select:
        {u.model, sum(u.input_tokens), sum(u.output_tokens), sum(u.cache_read_tokens),
         sum(u.cache_creation_tokens), count(u.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{cost: 0.0, input_tokens: 0, output_tokens: 0, calls: 0}, fn
      {model, input, output, cache_read, cache_write, calls}, acc ->
        %{
          cost: acc.cost + cost(model, input, output, cache_read, cache_write),
          input_tokens: acc.input_tokens + (input || 0),
          output_tokens: acc.output_tokens + (output || 0),
          calls: acc.calls + calls
        }
    end)
  end

  @doc """
  Per-day API spend for the last `days` days (oldest → newest), each split by purpose.
  Each day: `%{date, total, by_purpose: [%{purpose, cost}]}` (USD, highest cost first).
  """
  def usage_by_day(days) do
    today = Clock.today()
    start_date = Date.add(today, -(days - 1))
    {start, _finish} = Clock.day_range(start_date)

    by_day =
      from(u in ApiUsage,
        where: u.inserted_at >= ^start,
        select:
          {u.inserted_at, u.purpose, u.model, u.input_tokens, u.output_tokens,
           u.cache_read_tokens, u.cache_creation_tokens}
      )
      |> Repo.all()
      |> Enum.group_by(fn row -> Clock.to_logical_date(elem(row, 0)) end)

    for date <- Date.range(start_date, today) do
      by_purpose =
        by_day
        |> Map.get(date, [])
        |> Enum.group_by(&elem(&1, 1))
        |> Enum.map(fn {purpose, rows} ->
          cost =
            Enum.reduce(rows, 0.0, fn {_t, _p, model, input, output, cr, cw}, acc ->
              acc + cost(model, input, output, cr, cw)
            end)

          %{purpose: purpose, cost: cost}
        end)
        |> Enum.sort_by(& &1.cost, :desc)

      %{date: date, by_purpose: by_purpose, total: sum(by_purpose, & &1.cost)}
    end
  end

  @doc "Per-feature spend, highest cost first: `[%{purpose, cost, calls}]`."
  def usage_by_purpose do
    from(u in ApiUsage,
      group_by: [u.purpose, u.model],
      select:
        {u.purpose, u.model, sum(u.input_tokens), sum(u.output_tokens), sum(u.cache_read_tokens),
         sum(u.cache_creation_tokens), count(u.id)}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {purpose, rows} ->
      {cost, calls} =
        Enum.reduce(rows, {0.0, 0}, fn {_p, model, input, output, cr, cw, n}, {c, k} ->
          {c + cost(model, input, output, cr, cw), k + n}
        end)

      %{purpose: purpose, cost: cost, calls: calls}
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  defp cost(model, input, output, cache_read, cache_write) do
    p = pricing_for(model)

    ((input || 0) * p.input + (output || 0) * p.output + (cache_read || 0) * p.cache_read +
       (cache_write || 0) * p.cache_write) / 1_000_000
  end

  defp pricing_for(model) do
    model = model || ""

    tier =
      cond do
        String.contains?(model, "opus") -> "opus"
        String.contains?(model, "haiku") -> "haiku"
        true -> @default_tier
      end

    @pricing[tier]
  end

  @doc "Formats a USD `amount` compactly: `$1.23`, `<$0.01`, or `$0.00`."
  def format_cost(amount) when is_number(amount) do
    cond do
      amount <= 0 -> "$0.00"
      amount < 0.01 -> "<$0.01"
      true -> "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)
    end
  end

  @doc "Formats a token count compactly: `1.2M`, `34.5k`, `812`."
  def format_tokens(n) when is_integer(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}k"
      true -> Integer.to_string(n)
    end
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
    |> Enum.count(fn [_, inner] ->
      case marker_before_after(inner) do
        {before, after_} -> before != after_
        :malformed -> false
      end
    end)
  end

  # Replace each marker with the student's original text for word counting.
  defp strip_markers(text) do
    Regex.replace(@marker, text || "", fn whole, inner ->
      case marker_before_after(inner) do
        {before, _after} -> before
        :malformed -> whole
      end
    end)
  end

  # Marker inner -> {before, after}, tolerating the legacy "N:" id prefix. A marker with no ||
  # delimiter is :malformed (skipped/left as-is).
  defp marker_before_after(inner) do
    case String.split(Regex.replace(~r/^\d+:/, inner, ""), "||") do
      [_single] -> :malformed
      [before | rest] -> {before, List.first(rest) || ""}
    end
  end

  defp within?(date, start, finish) do
    Date.compare(date, start) != :lt and Date.compare(date, finish) != :gt
  end

  defp sum(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp rate(_corrections, 0), do: nil
  defp rate(corrections, words), do: Float.round(corrections * 100 / words, 1)
end
