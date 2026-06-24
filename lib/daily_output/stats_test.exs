defmodule DailyOutput.StatsTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Clock, Conversations, Journal, Repo, Stats}
  alias DailyOutput.Conversations.Conversation
  alias DailyOutput.Journal.Entry

  describe "correction_count/1" do
    test "counts valid markers, ignoring empty and malformed ones" do
      text = "[[1:a||b]] [[2:||x]] [[3:y||]] [[4:||]] [[5:nopipe]] plain"
      # valid: a||b, insertion ||x, deletion y|| ; skipped: both-empty, no-delimiter
      assert Stats.correction_count(text) == 3
    end

    test "zero for plain text" do
      assert Stats.correction_count("just some words") == 0
    end
  end

  describe "word_count/1" do
    test "counts the original (written) text, markers reduced to what was written" do
      assert Stats.word_count("[[1:Ich gehen||Ich gehe]] jeden Tag") == 4
    end

    test "zero for empty" do
      assert Stats.word_count("") == 0
    end
  end

  describe "error_rate/1" do
    test "corrections per 100 words" do
      assert Stats.error_rate("[[1:foo||bar]] one two three") == 25.0
    end

    test "nil when there are no words" do
      assert is_nil(Stats.error_rate(""))
    end
  end

  describe "overview/0" do
    test "aggregates words, sessions, active days, and weekly trend" do
      today = Clock.today()
      complete(Entry, today, "[[1:foo||bar]] one two three")
      complete(Conversation, today, "hallo welt")

      o = Stats.overview()

      assert o.total_words == 6
      assert o.entries == 1
      assert o.conversations == 1
      assert o.active_days == 1
      assert o.focus_mastered == 0

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

    test "conversations are counted from per-message corrections, not a batch blob" do
      today = Clock.today()

      {:ok, convo} = Conversations.create_conversation(%{topic: "x", language: "de"})

      {:ok, user_msg} =
        Conversations.add_message(convo, %{role: "user", body: "Ich gehe heim"})

      {:ok, _} = Conversations.add_message(convo, %{role: "assistant", body: "Schön!"})

      {:ok, _} =
        Conversations.save_message_feedback(user_msg, %{
          "annotated_text" => "Ich [[1:gehe||ging]] heim",
          "annotations" => [%{"id" => 1, "explanation" => "x", "category" => "verb"}]
        })

      at = DateTime.new!(today, ~T[12:00:00], "Etc/UTC")

      {1, _} =
        Repo.update_all(
          from(r in Conversation, where: r.id == ^convo.id),
          # Assessment-shaped feedback: no annotated_text blob to fall back on.
          set: [inserted_at: at, completed_at: at, feedback: %{"encouragement" => "x"}]
        )

      o = Stats.overview()

      # "Ich gehe heim" → 3 words, 1 correction (counted from the message, not the convo).
      assert o.conversations == 1
      assert o.total_words == 3
      assert List.last(o.trend).error_rate == 33.3
    end
  end

  defp complete(schema, date, annotated_text) do
    {:ok, record} =
      case schema do
        Entry -> Journal.create_entry(%{body: "x", language: "de"})
        Conversation -> Conversations.create_conversation(%{topic: "x", language: "de"})
      end

    at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(r in schema, where: r.id == ^record.id),
        set: [inserted_at: at, completed_at: at, feedback: %{"annotated_text" => annotated_text}]
      )

    record
  end
end
