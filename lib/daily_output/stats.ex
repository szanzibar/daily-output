defmodule DailyOutput.Stats do
  @moduledoc """
  Aggregates the feedback the app already produces into progress metrics — the
  "I'm actually improving" view.

  Every completed entry and conversation carries `feedback["annotated_text"]`, where
  corrections are marked `[[id:original||corrected]]`. From that single field we derive,
  uniformly across entries and conversations:

    * **words written** — the user's text with markers reduced to what they wrote
    * **corrections** — the number of correction markers

  The headline metric is **corrections per 100 words by week** — when it trends down,
  you're getting better.
  """

  import Ecto.Query

  alias DailyOutput.{Clock, Repo}
  alias DailyOutput.Journal.Entry
  alias DailyOutput.Conversations.Conversation
  alias DailyOutput.FocusTopics.FocusTopic

  @marker ~r/\[\[(\d+):([\s\S]*?)\]\]/

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
      recap: recap(samples, today)
    }
  end

  @doc "Corrections per 100 words across `text`, or nil when there are no words."
  def error_rate(text) do
    rate(correction_count(text), word_count(text))
  end

  # ── internals ──────────────────────────────────────────

  defp samples do
    rows(Entry, :entry) ++ rows(Conversation, :conversation)
  end

  defp rows(schema, type) do
    from(r in schema,
      where: is_nil(r.deleted_at) and not is_nil(r.feedback) and not is_nil(r.completed_at),
      select: {r.inserted_at, r.feedback}
    )
    |> Repo.all()
    |> Enum.map(fn {inserted_at, feedback} ->
      text = feedback["annotated_text"] || ""

      %{
        type: type,
        date: Clock.to_logical_date(inserted_at),
        words: word_count(text),
        corrections: correction_count(text)
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
