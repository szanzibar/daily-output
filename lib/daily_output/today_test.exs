defmodule DailyOutput.TodayTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Activities, Clock, Planner, Today}
  alias DailyOutput.Activities.{Activity, Message}
  alias DailyOutput.Flashcards.{Card, CompletedDay}

  @card %Card{target_text: "Ich ging nach Hause.", native_text: "I went home.", language: "de"}

  describe "next_step/0" do
    test "a fresh day creates the main activity" do
      assert {:activity, activity} = Today.next_step()
      assert activity.date == Clock.today()
      assert activity.kind in ~w(conversation journal)
      assert is_binary(activity.angle)
      # Cold start: no mistakes yet, so the category is left for the AI to pick.
      assert activity.focus == %{"category" => nil}
    end

    test "resuming mid-day returns the same activity" do
      {:activity, first} = Today.next_step()
      {:activity, again} = Today.next_step()

      assert again.id == first.id
      assert length(Activities.today()) == 1
    end

    test "yesterday's unfinished activity is abandoned for a fresh one" do
      yesterday = Activities.create(%{kind: "journal", date: Date.add(Clock.today(), -1)})

      {:activity, activity} = Today.next_step()

      assert activity.id != yesterday.id
      assert activity.date == Clock.today()
      # Never two journal days in a row.
      assert activity.kind == "conversation"
    end

    test "the focus comes from recent mistakes and rests after use" do
      Activities.create(%{
        kind: "conversation",
        date: Date.add(Clock.today(), -1),
        focus: %{"category" => "case"},
        feedback: %{
          "annotated_text" =>
            "[[der||den||case||a]] [[dem||den||case||b]] [[gehe||ging||verb||c]] Hund"
        },
        completed_at: DateTime.utc_now()
      })

      assert {:activity, %{focus: %{"category" => "verb"}}} = Today.next_step()
    end

    test "a completed activity moves on to cards" do
      Repo.insert!(@card)
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)

      assert Today.next_step() == :cards
    end

    test "with nothing due the cards are skipped, and the day is recorded" do
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)

      assert Today.next_step() == :done
      assert Repo.get_by(CompletedDay, day: Clock.today())
    end

    test "finishing the cards is done" do
      Repo.insert!(@card)
      {:activity, activity} = Today.next_step()
      Activities.complete(activity, %{}, nil)
      Today.finish_cards()

      assert Today.next_step() == :done
      assert Today.streak().today_status == :passed
    end

    test "the bonus is the other kind with the same focus, then done again" do
      {:activity, main} = Today.next_step()
      Activities.complete(main, %{}, nil)
      assert Today.next_step() == :done

      bonus = Today.start_bonus()

      assert bonus.kind != main.kind
      assert bonus.focus == main.focus
      assert bonus.angle != main.angle
      assert {:activity, %{id: id}} = Today.next_step()
      assert id == bonus.id

      Activities.complete(bonus, %{}, nil)
      assert Today.next_step() == :done
      assert %{today_status: :bonus, freezes_available: 1} = Today.streak()
    end

    test "the bonus needs a passed day, and there's only one" do
      {:activity, main} = Today.next_step()
      assert Today.start_bonus() == nil

      Activities.complete(main, %{}, nil)
      Today.next_step()
      assert Today.start_bonus()
      assert Today.start_bonus() == nil
    end
  end

  test "streak/0 counts passed days from completed activities and card days" do
    yesterday = Date.add(Clock.today(), -1)
    Activities.create(%{kind: "journal", date: yesterday, completed_at: DateTime.utc_now()})
    Repo.insert!(%CompletedDay{day: yesterday})

    assert Today.streak() == %{count: 1, freezes_available: 0, today_status: :pending}
  end

  test "journal_seconds_left/1 counts down 5 minutes of logged time" do
    assert Today.journal_seconds_left(0) == 300
    assert Today.journal_seconds_left(299) == 1
    assert Today.journal_seconds_left(300) == 0
    assert Today.journal_seconds_left(900) == 0
  end

  test "conversation_over?/1 after the 5th user message" do
    four = List.duplicate(%Message{role: "user"}, 4) ++ [%Message{role: "assistant"}]

    refute Today.conversation_over?(%Activity{messages: four})
    assert Today.conversation_over?(%Activity{messages: [%Message{role: "user"} | four]})
  end

  @focus %{"category" => "verb", "title" => "Perfekt mit sein", "body" => "Bewegung: sein."}

  describe "prepare/1" do
    test "writes the focus from your mistakes, then the opener from last session" do
      Activities.create(%{
        kind: "journal",
        date: Date.add(Clock.today(), -1),
        summary: "You told me about your trip to Lucerne.",
        feedback: %{
          "annotated_text" => "Ich [[habe||bin||verb||Bewegung braucht sein]] gelaufen."
        },
        completed_at: DateTime.utc_now()
      })

      activity =
        Activities.create(%{kind: "conversation", angle: "story", focus: %{"category" => "verb"}})

      expect_ai(%{
        "category" => "case",
        "title" => "Perfekt mit sein",
        "body" => "Bewegung: sein."
      })

      expect_ai("Hoi! Was hast du als Kind gern gemacht?")

      assert {:ok, prepared} = Today.prepare(activity)
      assert prepared.focus == @focus
      assert prepared.prompt == "Hoi! Was hast du als Kind gern gemacht?"
      assert Activities.get!(activity.id).prompt == prepared.prompt

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => focus_prompt}]} | _
                         ]
                       }}

      assert focus_prompt =~ "habe → bin (Bewegung braucht sein)"
      assert focus_prompt =~ "native English speaker"

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => starter_prompt}]} | _
                         ]
                       }}

      assert starter_prompt =~ "Last session: You told me about your trip to Lucerne."
      assert starter_prompt =~ Planner.angle_instruction("story")
      assert starter_prompt =~ "«Perfekt mit sein» (Bewegung: sein.)"
    end

    test "on a cold start the AI picks the focus category" do
      activity = Activities.create(%{kind: "journal", angle: "plan", focus: %{"category" => nil}})

      expect_ai(%{"category" => "case", "title" => "Akkusativ", "body" => "Für + Akkusativ."})
      expect_ai("Plane ein Wochenende in den Bergen.")

      assert {:ok, %{focus: %{"category" => "case"}}} = Today.prepare(activity)

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => focus_prompt}]} | _
                         ]
                       }}

      assert focus_prompt =~ "no mistakes on record"

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => starter_prompt}]} | _
                         ]
                       }}

      assert starter_prompt =~ "first session"
    end

    test "a failed opener keeps the focus, so the retry only writes the opener" do
      activity = Activities.create(%{kind: "journal", angle: "plan", focus: %{"category" => nil}})

      expect_ai(@focus)

      Req.Test.expect(DailyOutput.AI, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "message" => "Invalid request.",
            "type" => "invalid_request_error",
            "param" => nil,
            "code" => nil
          }
        })
      end)

      assert {:error, _} = Today.prepare(activity)
      assert %{focus: @focus, prompt: nil} = Activities.get!(activity.id)

      expect_ai("Plane ein Wochenende in den Bergen.")
      assert {:ok, %{prompt: "Plane ein Wochenende in den Bergen."}} = Today.prepare(activity)
    end
  end

  describe "conversation turns" do
    test "correct_message/1 saves the corrections, with the turns before it as context" do
      activity =
        Activities.create(%{kind: "conversation", prompt: "Was hast du gestern gemacht?"})

      message = Activities.add_message(activity, "user", "Gestern ich habe gekocht.")

      expect_ai(%{
        "corrected" => "Gestern habe ich gekocht.",
        "corrections" => [
          %{
            "before" => "ich habe",
            "after" => "habe ich",
            "type" => "word-order",
            "explanation" => "V2"
          }
        ]
      })

      assert {:ok, corrected} = Today.correct_message(message)

      assert corrected.feedback == %{
               "annotated_text" =>
                 "Gestern [[ich||||word-order||V2]] habe [[||ich||word-order||V2]] gekocht."
             }

      assert Activities.get!(activity.id).messages |> hd() |> Map.fetch!(:feedback)

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"content" => [%{"text" => system}]},
                           %{"content" => [%{"text" => content}]}
                         ]
                       }}

      assert system =~ "native English speaker"
      assert system =~ "explanation text in Swiss Standard German"
      assert content =~ "Was hast du gestern gemacht?"
    end

    test "the reply to your 5th message wraps up, opener first" do
      activity = Activities.create(%{kind: "conversation", prompt: "Hoi! Wie gehts?"})

      for i <- 1..5 do
        Activities.add_message(activity, "user", "Nachricht #{i}")
        if i < 5, do: Activities.add_message(activity, "assistant", "Antwort #{i}")
      end

      expect_ai("Schön, bis bald!")

      assert {:ok, %Message{role: "assistant", body: "Schön, bis bald!"}} = Today.reply(activity)

      assert_received {:ai_request,
                       %{"input" => [%{"content" => [%{"text" => system}]}, first | _]}}

      assert system =~ "This is your last message"
      assert first["role"] == "assistant"
    end

    test "earlier replies keep the conversation going" do
      activity = Activities.create(%{kind: "conversation", prompt: "Hoi! Wie gehts?"})
      Activities.add_message(activity, "user", "Gut, danke!")

      expect_ai("Super! Was machst du heute?")

      assert {:ok, _} = Today.reply(activity)

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => system}]} | _
                         ]
                       }}

      assert system =~ "follow-up questions"
      refute system =~ "last message"
    end
  end

  describe "finish/1" do
    test "a journal is proofread, graded on the focus, and completed with its summary" do
      activity =
        Activities.create(%{kind: "journal", focus: @focus, body: "Ich bin gestern gelaufen."})

      expect_ai(%{
        "corrected" => "Ich bin gestern gelaufen.",
        "corrections" => [],
        "summary" => "You went for a run.",
        "focus_result" => %{"used" => true, "correct" => true, "comment" => "Richtig!"}
      })

      assert {:ok, done} = Today.finish(activity)
      assert done.completed_at
      assert done.summary == "You went for a run."

      assert done.feedback == %{
               "annotated_text" => "Ich bin gestern gelaufen.",
               "focus_result" => %{"used" => true, "correct" => true, "comment" => "Richtig!"}
             }

      assert_received {:ai_request,
                       %{
                         "input" => [
                           %{"role" => "system", "content" => [%{"text" => system}]} | _
                         ]
                       }}

      assert system =~ "«Perfekt mit sein» (Bewegung: sein.)"
    end

    test "a conversation gets its summary, focus grade, and improvement panel" do
      activity = Activities.create(%{kind: "conversation", prompt: "Hoi!", focus: @focus})
      message = Activities.add_message(activity, "user", "Das haus ist gross.")

      # Capitalization only, so no flashcards (and no AI call) come after.
      Activities.save_message_feedback(message, %{
        "annotated_text" => "Das [[haus||Haus||spelling||Nomen gross]] ist gross."
      })

      expect_ai(%{
        "summary" => "You described a house.",
        "focus_result" => %{"used" => false, "correct" => false, "comment" => "Nicht benutzt."}
      })

      assert {:ok, done} = Today.finish(activity)
      assert done.summary == "You described a house."
      assert done.feedback["focus_result"]["used"] == false
      assert done.feedback["improvement"]["late_rate"] == 25.0

      assert_received {:ai_request,
                       %{"input" => [_system, %{"content" => [%{"text" => transcript}]}]}}

      assert transcript =~ "Partner: Hoi!"
      assert transcript =~ "(fixed: haus → Haus)"
    end

    test "a message whose correction got lost is corrected before the review" do
      activity = Activities.create(%{kind: "conversation", prompt: "Hoi!", focus: @focus})
      message = Activities.add_message(activity, "user", "Das haus ist gross.")

      expect_ai(%{
        "corrected" => "Das Haus ist gross.",
        "corrections" => [
          %{"before" => "haus", "after" => "Haus", "type" => "spelling", "explanation" => "Nomen"}
        ]
      })

      expect_ai(%{
        "summary" => "You described a house.",
        "focus_result" => %{"used" => false, "correct" => false, "comment" => "Nicht benutzt."}
      })

      assert {:ok, done} = Today.finish(activity)
      assert Repo.get!(Message, message.id).feedback["annotated_text"] =~ "[[haus||Haus"
      assert done.feedback["improvement"]["late_rate"] == 25.0

      assert_received {:ai_request, _correction}

      assert_received {:ai_request,
                       %{"input" => [_system, %{"content" => [%{"text" => transcript}]}]}}

      assert transcript =~ "(fixed: haus → Haus)"
    end
  end
end
