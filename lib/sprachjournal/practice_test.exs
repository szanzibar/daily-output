defmodule Sprachjournal.PracticeTest do
  use Sprachjournal.DataCase

  alias Sprachjournal.Practice

  describe "extract_corrected_text/1" do
    test "replaces markers with corrected text" do
      input = "Ich [[1:habe||bin]] gestern [[2:gegangt||gegangen]]."
      assert Practice.extract_corrected_text(input) == "Ich bin gestern gegangen."
    end

    test "handles empty original (insertion)" do
      input = "Test [[1:||hier]] end"
      assert Practice.extract_corrected_text(input) == "Test hier end"
    end

    test "handles empty corrected (deletion)" do
      input = "Test [[1:extra||]] end"
      assert Practice.extract_corrected_text(input) == "Test  end"
    end

    test "handles text with no markers" do
      assert Practice.extract_corrected_text("just text") == "just text"
    end

    test "handles nil" do
      assert Practice.extract_corrected_text(nil) == ""
    end

    test "handles empty string" do
      assert Practice.extract_corrected_text("") == ""
    end

    test "handles special characters in markers" do
      input = "Test [[1:B?||B!]] end"
      assert Practice.extract_corrected_text(input) == "Test B! end"
    end

    test "handles multiple markers on same line" do
      input = "[[1:a||b]] und [[2:c||d]]"
      assert Practice.extract_corrected_text(input) == "b und d"
    end
  end

  describe "extract_conversation_texts/1" do
    test "splits by MSG_BREAK and extracts each" do
      input = "Ich [[1:habe||bin]] hier\n---MSG_BREAK---\nDas ist [[2:gut||super]]"
      result = Practice.extract_conversation_texts(input)
      assert result == ["Ich bin hier", "Das ist super"]
    end

    test "handles nil" do
      assert Practice.extract_conversation_texts(nil) == []
    end
  end

  describe "compare_chars/2" do
    test "all correct" do
      result = Practice.compare_chars("abc", "abc")
      assert result.completed == true
      assert Enum.all?(result.compared, fn {_, s} -> s == :correct end)
      assert result.remaining == ""
    end

    test "marks wrong characters" do
      result = Practice.compare_chars("axc", "abc")
      assert Enum.at(result.compared, 0) == {"a", :correct}
      assert Enum.at(result.compared, 1) == {"x", :wrong}
      assert Enum.at(result.compared, 2) == {"c", :correct}
    end

    test "shows remaining untyped text" do
      result = Practice.compare_chars("ab", "abcde")
      assert result.remaining == "cde"
      assert result.progress == 2
      assert result.total == 5
    end

    test "completed when full correct match" do
      result = Practice.compare_chars("hello", "hello")
      assert result.completed == true
    end

    test "not completed with errors" do
      result = Practice.compare_chars("hellx", "hello")
      assert result.completed == false
    end

    test "empty typed" do
      result = Practice.compare_chars("", "target")
      assert result.compared == []
      assert result.remaining == "target"
      assert result.progress == 0
    end

    test "handles unicode/umlauts" do
      result = Practice.compare_chars("ü", "ü")
      assert result.compared == [{"ü", :correct}]
    end
  end

  describe "mark_entry_practiced/1" do
    test "sets practiced_at" do
      {:ok, entry} = Sprachjournal.Journal.create_entry(%{body: "test", language: "de"})
      assert is_nil(entry.practiced_at)
      {:ok, practiced} = Practice.mark_entry_practiced(entry)
      refute is_nil(practiced.practiced_at)
    end
  end

  describe "mark_conversation_practiced/1" do
    test "sets practiced_at" do
      {:ok, convo} =
        Sprachjournal.Conversations.create_conversation(%{topic: "test", language: "de"})

      assert is_nil(convo.practiced_at)
      {:ok, practiced} = Practice.mark_conversation_practiced(convo)
      refute is_nil(practiced.practiced_at)
    end
  end

  describe "daily_challenge_status/1" do
    test "returns :none for both with no activity" do
      status = Practice.daily_challenge_status(true)
      assert status.entry == :none
      assert status.conversation == :none
      assert status.all_done == false
    end

    test "entry with feedback but no practice is :half" do
      {:ok, entry} = Sprachjournal.Journal.create_entry(%{body: "test", language: "de"})
      Sprachjournal.Journal.save_feedback(entry, %{"annotated_text" => "test"})
      status = Practice.daily_challenge_status(true)
      assert status.entry == :half
    end

    test "entry with feedback and practice is :complete" do
      {:ok, entry} = Sprachjournal.Journal.create_entry(%{body: "test", language: "de"})
      {:ok, entry} = Sprachjournal.Journal.save_feedback(entry, %{"annotated_text" => "test"})
      Practice.mark_entry_practiced(entry)
      status = Practice.daily_challenge_status(true)
      assert status.entry == :complete
    end

    test "with practice disabled, feedback alone is :complete" do
      {:ok, entry} = Sprachjournal.Journal.create_entry(%{body: "test", language: "de"})
      Sprachjournal.Journal.save_feedback(entry, %{"annotated_text" => "test"})
      status = Practice.daily_challenge_status(false)
      assert status.entry == :complete
    end
  end
end
