defmodule DailyOutput.AI.LanguageProfile do
  @moduledoc """
  Centralized language profile data for AI prompt generation.

  Start from a generic language baseline and optionally layer in
  locale-specific conventions (for example: Swiss German conventions for "de").
  """

  @language_names %{
    "de" => "German",
    "en" => "English",
    "es" => "Spanish",
    "fr" => "French",
    "it" => "Italian",
    "pt" => "Portuguese",
    "ja" => "Japanese"
  }

  @profiles %{
    "ja" => %{
      prompt_name: "Japanese written in rōmaji (romanized Japanese)",
      locale_context: nil,
      settings_context: "Rōmaji",
      conventions: [
        "Always write Japanese in rōmaji (Latin-alphabet transliteration). Never output kanji, hiragana, or katakana — the learner studies with romanized text only",
        "Use Hepburn romanization (shi, chi, tsu, fu; mark long vowels consistently as ō/ū or doubled vowels)",
        "Separate words with spaces for readability (Japanese script has no spaces, but learner rōmaji should)"
      ]
    },
    "de" => %{
      prompt_name: "Swiss Standard German (Schweizer Hochdeutsch)",
      locale_context: "in Switzerland",
      settings_context: "Schweizer Hochdeutsch",
      conventions: [
        "Always write in Standard German (Schweizer Hochdeutsch). Never reply in Swiss German dialect (Mundart / Schwiizerdütsch), even in casual conversation",
        "Never use ß — always use ss (for example: \"dass\" not \"daß\", \"Strasse\" not \"Straße\")",
        "Prefer Swiss standard terms naturally when suitable (Velo, Poulet, Trottoir, parkieren, etc.)",
        "Use Swiss conventions for dates, numbers, and spelling where they differ from Germany usage"
      ]
    }
  }

  def resolve(target_language) when is_binary(target_language) do
    code = normalize_code(target_language)
    language_name = Map.get(@language_names, code, String.upcase(code))

    base_profile = %{
      code: code,
      language_name: language_name,
      prompt_name: language_name,
      locale_context: nil,
      settings_context: nil,
      conventions: []
    }

    Map.merge(base_profile, Map.get(@profiles, code, %{}))
  end

  def conventions_block(profile) do
    profile.conventions
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp normalize_code(target_language) do
    target_language
    |> String.trim()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> List.first()
  end
end
