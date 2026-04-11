defmodule DailyOutput.AI.LanguageProfileTest do
  use ExUnit.Case, async: true

  alias DailyOutput.AI.LanguageProfile

  test "applies Swiss conventions for German" do
    profile = LanguageProfile.resolve("de")

    assert profile.prompt_name == "Swiss Standard German (Schweizer Hochdeutsch)"
    assert profile.locale_context == "in Switzerland"
    assert profile.settings_context == "Schweizer Hochdeutsch"
    assert profile.conventions != []
    assert LanguageProfile.conventions_block(profile) =~ "Never use ß"
  end

  test "normalizes regional German code" do
    profile = LanguageProfile.resolve("de-CH")

    assert profile.code == "de"
    assert profile.prompt_name == "Swiss Standard German (Schweizer Hochdeutsch)"
  end

  test "keeps non-German languages generic" do
    profile = LanguageProfile.resolve("en")

    assert profile.prompt_name == "English"
    assert is_nil(profile.locale_context)
    assert is_nil(profile.settings_context)
    assert profile.conventions == []
    assert LanguageProfile.conventions_block(profile) == ""
  end
end
