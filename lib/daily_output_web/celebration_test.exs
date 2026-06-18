defmodule DailyOutputWeb.CelebrationTest do
  use ExUnit.Case, async: true

  alias DailyOutputWeb.Celebration

  describe "after_completion/2" do
    test "a completed day beats a streak milestone" do
      assert Celebration.after_completion(true, 7) == "day"
    end

    test "a milestone streak fires when the day isn't full yet" do
      assert Celebration.after_completion(false, 7) == "streak-7"
    end

    test "nothing for an ordinary, not-yet-full day" do
      assert Celebration.after_completion(false, 4) == nil
    end
  end

  describe "event/1" do
    test "day token carries localized copy" do
      assert %{kind: "day", message: msg} = Celebration.event("day")
      assert is_binary(msg)
    end

    test "streak token parses the count" do
      assert %{kind: "streak", count: 14, message: msg} = Celebration.event("streak-14")
      assert msg =~ "14"
    end

    test "garbage tokens are ignored" do
      assert Celebration.event("streak-nope") == nil
      assert Celebration.event("nonsense") == nil
    end
  end
end
