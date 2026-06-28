defmodule DailyOutput.Flashcards.ClozeTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Cloze

  @text "Ich ging nach Hause."

  describe "segments/2" do
    test "splits the answer into shown words and one blank per missed word" do
      assert Cloze.segments(@text, [1]) == [
               {:shown, "Ich"},
               {:blank, 1, "ging"},
               {:shown, "nach Hause."}
             ]
    end

    test "collapses a run of consecutive missed words into a single multi-word blank" do
      assert Cloze.segments(@text, [1, 2]) == [
               {:shown, "Ich"},
               {:blank, 1, "ging nach"},
               {:shown, "Hause."}
             ]
    end

    test "non-adjacent missed words become separate blanks" do
      assert Cloze.segments(@text, [1, 3]) == [
               {:shown, "Ich"},
               {:blank, 1, "ging"},
               {:shown, "nach"},
               {:blank, 3, "Hause."}
             ]
    end

    test "a leading blank keys off index 0" do
      assert Cloze.segments(@text, [0]) == [{:blank, 0, "Ich"}, {:shown, "ging nach Hause."}]
    end
  end

  describe "evaluate/3 — full answer (nil mask)" do
    test "an exact answer passes with no warning and no mask" do
      v = Cloze.evaluate(@text, nil, @text)
      assert v.result == :pass
      assert v.exact?
      assert v.case_diffs == []
      assert v.new_blank_indices == nil
      assert v.diff == nil
    end

    test "a case-only answer still passes but flags the capitalization" do
      v = Cloze.evaluate(@text, nil, "ich ging nach hause.")
      assert v.result == :pass
      refute v.exact?

      assert v.case_diffs == [
               %{typed: "ich", expected: "Ich"},
               %{typed: "hause.", expected: "Hause."}
             ]

      assert v.new_blank_indices == nil
    end

    test "a single wrong word fails and narrows the mask to just that word" do
      v = Cloze.evaluate(@text, nil, "Ich gehe nach Hause.")
      assert v.result == :fail
      assert v.new_blank_indices == [1]
      assert is_list(v.diff)
    end

    test "getting everything wrong keeps a full-answer prompt (nil mask)" do
      v = Cloze.evaluate(@text, nil, "falsch")
      assert v.result == :fail
      assert v.new_blank_indices == nil
    end

    test "a capitalization slip is never added to the fill-in mask, even on a miss" do
      # "ich" is just miscapitalized (index 0); "gehe" is genuinely wrong (index 1).
      v = Cloze.evaluate(@text, nil, "ich gehe nach Hause.")
      assert v.result == :fail
      assert v.new_blank_indices == [1]
    end
  end

  describe "evaluate/3 — cloze (with mask)" do
    test "filling the blank correctly passes and holds the mask steady" do
      v = Cloze.evaluate(@text, [1], %{1 => "ging"})
      assert v.result == :pass
      assert v.exact?
      assert v.new_blank_indices == [1]
    end

    test "the right word in the wrong case passes with a capitalization warning" do
      v = Cloze.evaluate(@text, [1], %{1 => "GING"})
      assert v.result == :pass
      assert v.case_diffs == [%{typed: "GING", expected: "ging"}]
      assert v.new_blank_indices == [1]
    end

    test "a wrong blank fails and the mask stays on that word" do
      v = Cloze.evaluate(@text, [1], %{1 => "gehe"})
      assert v.result == :fail
      assert v.new_blank_indices == [1]
    end

    test "a multi-word blank narrows to only the still-wrong word" do
      # Blank covers "ging nach"; the learner gets "ging" right, "nach" wrong.
      v = Cloze.evaluate(@text, [1, 2], %{1 => "ging falsch"})
      assert v.result == :fail
      assert v.new_blank_indices == [2]
    end

    test "filling a multi-word blank correctly passes and keeps the span" do
      v = Cloze.evaluate(@text, [1, 2], %{1 => "ging nach"})
      assert v.result == :pass
      assert v.new_blank_indices == [1, 2]
    end

    test "an empty blank fails" do
      v = Cloze.evaluate(@text, [1], %{})
      assert v.result == :fail
    end
  end
end
