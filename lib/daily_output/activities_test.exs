defmodule DailyOutput.ActivitiesTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Activities, Clock}

  test "create/1 stamps today's logical date" do
    activity = Activities.create(%{kind: "journal"})
    assert activity.date == Clock.today()
    assert activity.messages == []
  end

  test "get!/1 preloads messages oldest first" do
    activity = Activities.create(%{kind: "conversation"})
    first = Activities.add_message(activity, "assistant", "Hallo!")
    second = Activities.add_message(activity, "user", "Hoi")

    assert Enum.map(Activities.get!(activity.id).messages, & &1.id) == [first.id, second.id]
  end

  test "today/0 and recent/1 match on the stored date" do
    yesterday = Date.add(Clock.today(), -1)
    old = Activities.create(%{kind: "journal", date: Date.add(Clock.today(), -10)})
    past = Activities.create(%{kind: "journal", date: yesterday})
    now = Activities.create(%{kind: "conversation"})

    assert Enum.map(Activities.today(), & &1.id) == [now.id]
    assert Enum.map(Activities.recent(3), & &1.id) == [now.id, past.id]
    assert old.id in Enum.map(Activities.recent(10), & &1.id)
  end

  test "correction_categories/1 reads the journal feedback and each message's" do
    Activities.create(%{
      kind: "journal",
      feedback: %{"annotations" => [%{"category" => "case"}, %{"category" => "verb"}]}
    })

    conversation = Activities.create(%{kind: "conversation"})
    message = Activities.add_message(conversation, "user", "Ich gehen")
    Activities.save_message_feedback(message, %{"annotations" => [%{"category" => "verb"}]})
    Activities.add_message(conversation, "assistant", "Schön!")

    assert Enum.sort(Activities.correction_categories(Activities.today())) == ~w(case verb verb)
  end

  test "save_body/2 keeps the journal draft" do
    activity = Activities.create(%{kind: "journal"})
    Activities.save_body(activity, "Heute habe ich")
    assert Activities.get!(activity.id).body == "Heute habe ich"
  end

  test "complete/3 stamps the review and returns the activity with messages" do
    activity = Activities.create(%{kind: "conversation"})
    Activities.add_message(activity, "user", "Hoi")

    completed = Activities.complete(activity, %{"commentary" => []}, "We said hi.")

    assert completed.completed_at
    assert completed.feedback == %{"commentary" => []}
    assert completed.summary == "We said hi."
    assert [%{body: "Hoi"}] = completed.messages
    assert [%{id: id}] = Activities.completed()
    assert id == activity.id
  end

  describe "mistake_analysis/1" do
    test "a category flagged once early, then never again, is resolved" do
      messages = [
        %{
          role: "user",
          body: "eins zwei drei",
          feedback: %{"annotations" => [%{"category" => "gender"}]}
        },
        %{role: "assistant", body: "ok", feedback: nil},
        %{role: "user", body: "vier funf sechs", feedback: nil},
        %{role: "user", body: "sieben acht neun", feedback: nil}
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["resolved_categories"] == ["gender"]
      assert analysis["repeated_categories"] == []
    end

    test "a category that recurs across messages is still repeating" do
      messages = [
        %{
          role: "user",
          body: "eins zwei drei",
          feedback: %{"annotations" => [%{"category" => "case"}]}
        },
        %{
          role: "user",
          body: "vier funf sechs",
          feedback: %{"annotations" => [%{"category" => "case"}]}
        },
        %{role: "user", body: "sieben acht neun", feedback: nil}
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["repeated_categories"] == ["case"]
      assert analysis["resolved_categories"] == []
    end

    test "computes early vs late corrections per 100 words" do
      messages = [
        %{
          role: "user",
          body: "eins zwei drei",
          feedback: %{"annotations" => [%{"category" => "verb"}]}
        },
        %{role: "user", body: "vier funf sechs", feedback: %{"annotations" => []}}
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["early_rate"] == 33.3
      assert analysis["late_rate"] == 0.0
      assert analysis["total_corrections"] == 1
      assert analysis["by_category"] == %{"verb" => 1}
    end

    test "a category only in the final message is neither resolved nor repeating" do
      messages = [
        %{role: "user", body: "eins zwei drei", feedback: nil},
        %{
          role: "user",
          body: "vier funf sechs",
          feedback: %{"annotations" => [%{"category" => "case"}]}
        }
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["resolved_categories"] == []
      assert analysis["repeated_categories"] == []
    end

    test "a feedback-free conversation yields zeros" do
      analysis = Activities.mistake_analysis([%{role: "user", body: "hallo welt", feedback: nil}])

      assert analysis["total_corrections"] == 0
      assert is_nil(analysis["early_rate"])
      assert analysis["late_rate"] == 0.0
    end
  end
end
