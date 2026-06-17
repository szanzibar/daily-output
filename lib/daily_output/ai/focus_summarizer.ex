defmodule DailyOutput.AI.FocusSummarizer do
  @moduledoc """
  Summarizes a feedback tip into a concise, generic focus point
  that can be practiced in any future writing context.
  """

  alias DailyOutput.AI

  def summarize(tip_text) do
    system = """
    You are a language learning assistant. The student received a grammar/usage tip
    from their writing feedback. Summarize it into a concise, generic focus point
    that they can practice in ANY future writing — not just the context it came from.

    Rules:
    - 1-2 short sentences max
    - Include the grammar rule or pattern name if applicable
    - Make it self-contained — someone reading it tomorrow without context should understand what to practice
    - Write in the same language as the input

    Formatting (use Markdown, keep it minimal):
    - Wrap the rule or pattern name in **bold**
    - Wrap any inline foreign-language word or particle in *italics*
    - If you give an example sentence, put it on its own line as a blockquote starting with "> "
    - Do NOT use quotation marks for emphasis — use the Markdown above instead

    Respond with ONLY the summarized text, nothing else.
    """

    with {:ok, client} <- AI.client() do
      case AI.chat(client,
             system: system,
             messages: [%{role: "user", content: "Summarize this tip:\n\n#{tip_text}"}],
             max_tokens: 256
           ) do
        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          {:ok, String.trim(text)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
