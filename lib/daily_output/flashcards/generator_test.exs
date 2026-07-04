defmodule DailyOutput.Flashcards.GeneratorTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Flashcards.Generator

  describe "extract_cards/1 (tolerates sonnet-5's stringified tool output)" do
    test "a proper array" do
      cards = [%{"target_text" => "a", "native_text" => "b"}]
      assert Generator.extract_cards(%{"cards" => cards}) == cards
    end

    test "cards returned as a JSON string" do
      json = ~s({"cards":[{"target_text":"Ich bin müde.","native_text":"I am tired."}]})

      assert Generator.extract_cards(%{"cards" => json}) == [
               %{"target_text" => "Ich bin müde.", "native_text" => "I am tired."}
             ]
    end

    test "cards returned as a bare JSON array string" do
      json = ~s([{"target_text":"Hallo","native_text":"Hi"}])

      assert Generator.extract_cards(%{"cards" => json}) == [
               %{"target_text" => "Hallo", "native_text" => "Hi"}
             ]
    end

    test "malformed or unexpected input yields no cards" do
      assert Generator.extract_cards(%{"cards" => "not json"}) == []
      assert Generator.extract_cards(%{}) == []
      assert Generator.extract_cards(nil) == []
    end
  end
end
