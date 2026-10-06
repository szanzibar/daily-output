defmodule DailyOutput.ActivitiesTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Activities, Clock, Flashcards}

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

  test "update/2 keeps the journal draft" do
    activity = Activities.create(%{kind: "journal"})
    Activities.update(activity, %{body: "Heute habe ich"})
    assert Activities.get!(activity.id).body == "Heute habe ich"
  end

  test "corrections/1 reads the markers of the journal and each message" do
    journal =
      Activities.create(%{
        kind: "journal",
        feedback: %{"annotated_text" => "Ich [[gehe||ging||verb||Vergangenheit]]."}
      })

    conversation = Activities.create(%{kind: "conversation"})
    message = Activities.add_message(conversation, "user", "der Haus")

    Activities.save_message_feedback(message, %{
      "annotated_text" => "[[der||das||gender||Neutrum]] Haus"
    })

    assert [%{corrected: "ging", category: "verb"}, %{original: "der", explanation: "Neutrum"}] =
             Activities.corrections([journal, Activities.get!(conversation.id)])
  end

  test "complete/3 stamps the review and returns the activity with messages" do
    activity = Activities.create(%{kind: "conversation"})
    Activities.add_message(activity, "user", "Hoi")

    completed =
      Activities.complete(activity, %{"focus_result" => %{"used" => true}}, "We said hi.")

    assert completed.completed_at
    assert completed.feedback == %{"focus_result" => %{"used" => true}}
    assert completed.summary == "We said hi."
    assert [%{body: "Hoi"}] = completed.messages
    assert [%{id: id}] = Activities.completed()
    assert id == activity.id
  end

  test "complete/3 turns the corrections into flashcards" do
    activity = Activities.create(%{kind: "journal"})

    expect_ai(%{
      "cards" => [%{"target_text" => "Ich ging heim.", "native_text" => "I went home."}]
    })

    Activities.complete(activity, %{"annotated_text" => "Ich [[gehe||ging||verb||v]] heim."}, nil)

    assert [%{target_text: "Ich ging heim."}] = Flashcards.list_cards()
  end

  describe "mistake_analysis/1" do
    test "a category flagged once early, then never again, is resolved" do
      messages = [
        %{
          role: "user",
          body: "eins zwei drei",
          feedback: %{"annotated_text" => "[[eins||ein||gender||x]] zwei drei"}
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
          feedback: %{"annotated_text" => "[[eins||einen||case||x]] zwei drei"}
        },
        %{
          role: "user",
          body: "vier funf sechs",
          feedback: %{"annotated_text" => "vier [[funf||fünf||case||x]] sechs"}
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
          feedback: %{"annotated_text" => "eins [[zwei||zweit||verb||x]] drei"}
        },
        %{
          role: "user",
          body: "vier funf sechs",
          feedback: %{"annotated_text" => "vier funf sechs"}
        }
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["early_rate"] == 33.3
      assert analysis["late_rate"] == 0.0
    end

    test "a category only in the final message is neither resolved nor repeating" do
      messages = [
        %{role: "user", body: "eins zwei drei", feedback: nil},
        %{
          role: "user",
          body: "vier funf sechs",
          feedback: %{"annotated_text" => "vier [[funf||fünf||case||x]] sechs"}
        }
      ]

      analysis = Activities.mistake_analysis(messages)
      assert analysis["resolved_categories"] == []
      assert analysis["repeated_categories"] == []
    end

    test "a feedback-free conversation yields zeros" do
      analysis = Activities.mistake_analysis([%{role: "user", body: "hallo welt", feedback: nil}])

      assert is_nil(analysis["early_rate"])
      assert analysis["late_rate"] == 0.0
    end
  end
end
