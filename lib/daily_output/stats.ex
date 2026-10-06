defmodule DailyOutput.Stats do
  @moduledoc """
  Aggregates the feedback the app already produces into progress metrics — the
  "I'm actually improving" view.

  Corrections are marked `[[before||after||type||explanation]]`. From that we derive, the
  same way for journals and conversations:

    * **words written** — the user's text with markers reduced to what they wrote
    * **corrections** — the number of correction markers

  A journal carries one `feedback["annotated_text"]`. Conversations are corrected per
  message, so we sum each user message's own `feedback`.

  The headline metric is **corrections per 100 words by week** — when it trends down,
  you're getting better.
  """

  import Ecto.Query

  alias DailyOutput.{Clock, Repo}
  alias DailyOutput.Activities.Activity
  alias DailyOutput.Stats.{ApiUsage, TimeLog}

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
      journals: Enum.count(samples, &(&1.kind == "journal")),
      conversations: Enum.count(samples, &(&1.kind == "conversation")),
      active_days: samples |> Enum.map(& &1.date) |> Enum.uniq() |> length(),
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

  # USD per 1,000,000 tokens, picked by the tier name in the model id from any route. OpenAI
  # doesn't charge cache writes, and we never turn on Anthropic's prompt caching.
  @pricing %{
    sol: %{input: 2.0, output: 10.0, cache_read: 0.1},
    luna: %{input: 0.1, output: 0.5, cache_read: 0.01},
    sonnet: %{input: 2.0, output: 10.0, cache_read: 0.2}
  }

  @doc """
  Records one API call's token usage from the `AI.chat/2` `response`, tagged with
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
         count(u.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{cost: 0.0, input_tokens: 0, output_tokens: 0, calls: 0}, fn
      {model, input, output, cache_read, calls}, acc ->
        %{
          cost: acc.cost + cost(model, input, output, cache_read),
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
           u.cache_read_tokens}
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
            Enum.reduce(rows, 0.0, fn {_t, _p, model, input, output, cache_read}, acc ->
              acc + cost(model, input, output, cache_read)
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
         count(u.id)}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {purpose, rows} ->
      {cost, calls} =
        Enum.reduce(rows, {0.0, 0}, fn {_p, model, input, output, cache_read, n}, {c, k} ->
          {c + cost(model, input, output, cache_read), k + n}
        end)

      %{purpose: purpose, cost: cost, calls: calls}
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  @doc "USD cost of one call's tokens on `model`. `input` includes the `cache_read` tokens."
  def cost(model, input, output, cache_read) do
    model = model || ""

    p =
      cond do
        model =~ "luna" -> @pricing.luna
        model =~ "sonnet" -> @pricing.sonnet
        true -> @pricing.sol
      end

    cache_read = cache_read || 0

    (((input || 0) - cache_read) * p.input + cache_read * p.cache_read + (output || 0) * p.output) /
      1_000_000
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

  # One sample per completed activity. A journal's text is its feedback; a conversation's is
  # each user message's feedback, or its body when no correction came back.
  defp samples do
    from(a in Activity, where: not is_nil(a.completed_at), preload: :messages)
    |> Repo.all()
    |> Enum.map(fn activity ->
      texts =
        if activity.kind == "journal" do
          [activity.feedback["annotated_text"] || ""]
        else
          for msg <- activity.messages, msg.role == "user" do
            (is_map(msg.feedback) && msg.feedback["annotated_text"]) || msg.body
          end
        end

      %{
        kind: activity.kind,
        date: activity.date,
        words: sum(texts, &word_count/1),
        corrections: sum(texts, &correction_count/1)
      }
    end)
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
      error_rate: rate(sum(window, & &1.corrections), words)
    }
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

  # Marker inner -> {before, after}. A marker with no || delimiter is :malformed.
  defp marker_before_after(inner) do
    case String.split(inner, "||") do
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
