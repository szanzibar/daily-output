defmodule DailyOutput.StatsTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Activities, Clock, Repo, Stats}
  alias DailyOutput.Stats.ApiUsage

  describe "correction_count/1" do
    test "counts valid markers, ignoring empty and malformed ones" do
      text = "[[a||b||verb||v]] [[||x]] [[y||]] [[||]] [[nopipe]] plain"
      # valid: a||b, insertion ||x, deletion y|| ; skipped: both-empty, no-delimiter
      assert Stats.correction_count(text) == 3
    end

    test "zero for plain text" do
      assert Stats.correction_count("just some words") == 0
    end
  end

  describe "word_count/1" do
    test "counts the original (written) text, markers reduced to what was written" do
      assert Stats.word_count("[[Ich gehen||Ich gehe||verb||v]] jeden Tag") == 4
    end

    test "zero for empty" do
      assert Stats.word_count("") == 0
    end
  end

  describe "error_rate/1" do
    test "corrections per 100 words" do
      assert Stats.error_rate("[[foo||bar]] one two three") == 25.0
    end

    test "nil when there are no words" do
      assert is_nil(Stats.error_rate(""))
    end
  end

  describe "time tracking" do
    test "track/2 accumulates seconds per section for today" do
      Stats.track("flashcards", 30)
      Stats.track("flashcards", 45)
      Stats.track("journal", 60)

      today = Stats.time_today()
      assert today.flashcards == 75
      assert today.journal == 60
      assert today.conversation == 0
      assert today.total == 135
    end

    test "track/2 ignores unknown sections and non-positive seconds" do
      assert {:ok, :ignored} = Stats.track("bogus", 10)
      assert {:ok, :ignored} = Stats.track("flashcards", 0)
      assert Stats.time_today().total == 0
    end

    test "time_by_day/1 returns one ascending row per day including today" do
      Stats.track("conversation", 20)
      days = Stats.time_by_day(7)

      assert length(days) == 7
      assert List.last(days).date == Clock.today()
      assert List.last(days).conversation == 20
      assert hd(days).date == Date.add(Clock.today(), -6)
    end

    test "total_time/0 sums everything" do
      Stats.track("journal", 10)
      Stats.track("flashcards", 5)
      assert Stats.total_time() == 15
    end
  end

  describe "usage_by_day/1" do
    test "one ascending row per day; today is split by purpose, highest cost first" do
      today = Clock.today()
      # Sol pricing: $2/M input, $10/M output.
      log_usage("flashcards", "gpt-6.1-sol", input: 1_000_000)
      log_usage("proofread", "gpt-6.1-sol", output: 1_000_000)

      days = Stats.usage_by_day(7)

      assert length(days) == 7
      assert hd(days).date == Date.add(today, -6)

      last = List.last(days)
      assert last.date == today
      assert_in_delta last.total, 12.0, 0.0001

      assert Enum.map(last.by_purpose, & &1.purpose) == ["proofread", "flashcards"]
      assert_in_delta hd(last.by_purpose).cost, 10.0, 0.0001
    end

    test "quiet days have an empty breakdown and a zero total" do
      days = Stats.usage_by_day(7)
      assert length(days) == 7
      assert Enum.all?(days, &(&1.by_purpose == [] and &1.total == 0))
    end
  end

  describe "cost/4" do
    test "prices each tier by its direct and OpenRouter ids, cached input at the cache rate" do
      # 1M input, half of it cached, and 1M output.
      for model <- ["gpt-6.1-sol", "openai/gpt-6.1-sol"] do
        assert_in_delta Stats.cost(model, 1_000_000, 1_000_000, 500_000), 11.05, 1.0e-9
      end

      for model <- ["gpt-6-luna", "openai/gpt-6-luna"] do
        assert_in_delta Stats.cost(model, 1_000_000, 1_000_000, 500_000), 0.555, 1.0e-9
      end

      for model <- ["claude-sonnet-5-5", "anthropic/claude-sonnet-5.5"] do
        assert_in_delta Stats.cost(model, 1_000_000, 1_000_000, 500_000), 11.1, 1.0e-9
      end
    end
  end

  describe "format_duration/1" do
    test "formats hours and minutes compactly" do
      assert Stats.format_duration(0) == "0m"
      assert Stats.format_duration(30) == "<1m"
      assert Stats.format_duration(90) == "1m"
      assert Stats.format_duration(3600) == "1h"
      assert Stats.format_duration(3660) == "1h 1m"
    end
  end

  describe "overview/0" do
    test "aggregates words, activities, active days, and weekly trend" do
      Activities.create(%{
        kind: "journal",
        feedback: %{"annotated_text" => "[[foo||bar||verb||v]] one two three"},
        completed_at: DateTime.utc_now()
      })

      conversation = Activities.create(%{kind: "conversation", completed_at: DateTime.utc_now()})
      Activities.add_message(conversation, "user", "hallo welt")

      o = Stats.overview()

      assert o.total_words == 6
      assert o.journals == 1
      assert o.conversations == 1
      assert o.active_days == 1

      assert o.recap.days_active == 1
      assert o.recap.words == 6
      assert o.recap.error_rate == 16.7

      # Trend is one bucket per week, newest last; this week reflects the 6 words.
      assert length(o.trend) == 8
      assert List.last(o.trend).words == 6
      assert List.last(o.trend).error_rate == 16.7
    end

    test "empty history yields zeroes and nil rates" do
      o = Stats.overview()
      assert o.total_words == 0
      assert o.active_days == 0
      assert is_nil(List.last(o.trend).error_rate)
    end

    test "conversations count each user message's corrections" do
      conversation = Activities.create(%{kind: "conversation", completed_at: DateTime.utc_now()})
      message = Activities.add_message(conversation, "user", "Ich gehe heim")
      Activities.add_message(conversation, "assistant", "Schön!")

      Activities.save_message_feedback(message, %{
        "annotated_text" => "Ich [[gehe||ging||verb||v]] heim",
        "annotations" => [%{"explanation" => "x", "category" => "verb"}]
      })

      o = Stats.overview()

      # "Ich gehe heim" → 3 words, 1 correction; the partner's words don't count.
      assert o.conversations == 1
      assert o.total_words == 3
      assert List.last(o.trend).error_rate == 33.3
    end

    test "unfinished activities don't count" do
      Activities.create(%{kind: "journal", feedback: %{"annotated_text" => "one two"}})
      assert Stats.overview().total_words == 0
    end
  end

  # Records an API call today, pinning inserted_at so the logical-day bucketing is stable.
  defp log_usage(purpose, model, tokens) do
    {:ok, usage} =
      Repo.insert(%ApiUsage{
        purpose: purpose,
        model: model,
        input_tokens: Keyword.get(tokens, :input, 0),
        output_tokens: Keyword.get(tokens, :output, 0)
      })

    at = DateTime.new!(Clock.today(), ~T[12:00:00], "Etc/UTC")
    Repo.update_all(from(u in ApiUsage, where: u.id == ^usage.id), set: [inserted_at: at])
    usage
  end
end
