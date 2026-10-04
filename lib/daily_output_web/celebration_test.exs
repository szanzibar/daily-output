defmodule DailyOutputWeb.CelebrationTest do
  use ExUnit.Case, async: true

  alias DailyOutputWeb.Celebration

  test "the day token carries localized copy" do
    assert %{kind: "day", message: msg} = Celebration.event("day")
    assert is_binary(msg)
  end

  test "unknown tokens are ignored" do
    assert Celebration.event("nonsense") == nil
    assert Celebration.event(nil) == nil
  end
end
