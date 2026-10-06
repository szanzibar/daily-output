defmodule DailyOutput.AI.SessionStarterTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.SessionStarter

  test "normalize/1 trims the opener, and an empty one is a parse miss" do
    assert SessionStarter.normalize("\n Hoi! Wie gohts? \n") == {:ok, "Hoi! Wie gohts?"}
    assert SessionStarter.normalize("  ") == {:error, :unparsed}
  end
end
