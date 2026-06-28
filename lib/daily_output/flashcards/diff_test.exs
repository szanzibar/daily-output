defmodule DailyOutput.Flashcards.DiffTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Diff

  defp dels(ops), do: for(%{op: :del, text: t} <- ops, do: t)
  defp inss(ops), do: for(%{op: :ins, text: t} <- ops, do: t)
  defp eqs(ops), do: for(%{op: :eq, text: t} <- ops, do: t)
  defp cases(ops), do: for(%{op: :case, text: t} <- ops, do: t)

  test "identical answers are all equal" do
    ops = Diff.unified("Ich ging nach Hause.", "Ich ging nach Hause.")
    assert eqs(ops) == ["Ich", "ging", "nach", "Hause."]
    assert dels(ops) == []
    assert inss(ops) == []
  end

  test "a case-only difference is a soft warning, not a struck-out substitution" do
    ops = Diff.unified("Ich ging nach Hause.", "ich ging nach hause.")

    # The miscapitalized words align (no del/ins) and surface as :case warnings carrying
    # the correct capitalization.
    assert dels(ops) == []
    assert inss(ops) == []
    assert cases(ops) == ["Ich", "Hause."]
    assert eqs(ops) == ["ging", "nach"]
  end

  test "a substitution is the wrong word struck out then the correct word" do
    ops = Diff.unified("Ich ging nach Hause.", "Ich gehe nach Hause.")

    assert dels(ops) == ["gehe"]
    assert inss(ops) == ["ging"]
    # del comes immediately before ins, so it renders "gehe ging" (struck → green)
    assert Enum.map(ops, & &1.op) == [:eq, :del, :ins, :eq, :eq]
  end

  test "an umlaut difference is a substitution" do
    ops = Diff.unified("Das Mädchen lacht.", "Das Madchen lacht.")
    assert dels(ops) == ["Madchen"]
    assert inss(ops) == ["Mädchen"]
  end

  test "a missing word is an insertion with no deletion" do
    ops = Diff.unified("Ich gehe nach Hause.", "Ich gehe Hause.")
    assert dels(ops) == []
    assert inss(ops) == ["nach"]
  end

  test "an extra word is a deletion with no insertion" do
    ops = Diff.unified("Ich gehe Hause.", "Ich gehe nach Hause.")
    assert dels(ops) == ["nach"]
    assert inss(ops) == []
  end

  test "punctuation differences are caught" do
    ops = Diff.unified("Hallo, wie geht es dir?", "Hallo wie geht es dir?")
    assert "Hallo" in dels(ops)
    assert "Hallo," in inss(ops)
  end
end
