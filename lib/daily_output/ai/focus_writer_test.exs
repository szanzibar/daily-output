defmodule DailyOutput.AI.FocusWriterTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.FocusWriter

  @banner %{
    "category" => "case",
    "title" => " Akkusativ nach für ",
    "body" => " Für + Akkusativ. "
  }

  test "today's category beats the model's pick" do
    assert FocusWriter.normalize(@banner, "word-order") == %{
             "category" => "word-order",
             "title" => "Akkusativ nach für",
             "body" => "Für + Akkusativ."
           }
  end

  test "on a cold start the model's pick becomes the category" do
    assert FocusWriter.normalize(@banner, nil)["category"] == "case"
  end
end
