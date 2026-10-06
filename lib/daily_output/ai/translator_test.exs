defmodule DailyOutput.AI.TranslatorTest do
  use DailyOutput.DataCase

  alias DailyOutput.AI.Translator
  alias DailyOutput.Stats.ApiUsage

  test "asks for only the translation, into the native language by name" do
    expect_ai(" Hi! What are you up to today?\n")

    assert Translator.translate("Hoi! Was hast du heute vor?", "en") ==
             {:ok, "Hi! What are you up to today?"}

    assert_received {:ai_request, %{"input" => [system, text]}}
    assert [%{"text" => instructions}] = system["content"]
    assert instructions =~ "into English"
    assert instructions =~ "only the translation"
    assert [%{"text" => "Hoi! Was hast du heute vor?"}] = text["content"]
    assert [%{purpose: "translate"}] = Repo.all(ApiUsage)
  end
end
