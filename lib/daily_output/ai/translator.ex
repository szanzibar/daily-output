defmodule DailyOutput.AI.Translator do
  @moduledoc "Translates an AI text into your native language, for when you can't follow it."

  alias DailyOutput.AI
  alias DailyOutput.AI.LanguageProfile

  @doc "`text` in `native_language` (a code), as plain text."
  def translate(text, native_language) do
    native = LanguageProfile.resolve(native_language).language_name

    with {:ok, translation} <-
           AI.chat(
             purpose: "translate",
             system:
               "Translate the user's message into #{native}. Translate meaning for meaning, so it reads the way a native #{native} speaker would say it. Reply with only the translation as plain text: no preamble, quotes, notes, or Markdown.",
             messages: [%{role: "user", content: text}],
             # Headroom for reasoning tokens, which count against the cap.
             max_tokens: 2048
           ) do
      {:ok, String.trim(translation)}
    end
  end
end
