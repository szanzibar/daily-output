defmodule DailyOutput.AI.FocusWriter do
  @moduledoc """
  Writes today's focus banner: the rule and one example, built from your real mistakes in the
  focus category. With no category or no mistakes yet (cold start), it picks a grammar point
  that suits your level.
  """

  alias DailyOutput.AI
  alias DailyOutput.AI.{LanguageProfile, Proofreader}

  @doc """
  `mistakes` are `%{original, corrected, explanation}` maps, newest first. Returns
  `{:ok, %{"category", "title", "body"}}` or `{:error, reason}`.
  """
  def write(category, mistakes, opts) do
    target = Keyword.fetch!(opts, :target_language)
    native = LanguageProfile.resolve(Keyword.fetch!(opts, :native_language)).language_name
    level = Keyword.get(opts, :language_level, "B2")
    profile = LanguageProfile.resolve(target)
    feedback_lang = LanguageProfile.feedback_language(level, target, opts[:native_language])

    task =
      if mistakes == [] do
        "They have no mistakes on record yet. Pick one grammar point a CEFR #{level} learner of #{profile.prompt_name} often gets wrong and can practise in everyday talk."
      else
        """
        Their recent mistakes in the category "#{category}":
        #{Enum.map_join(mistakes, "\n", &"- #{&1.original} → #{&1.corrected} (#{&1.explanation})")}

        Find the one rule behind most of these and make it today's focus.
        """
      end

    conventions =
      if profile.conventions != [],
        do:
          "\nThe example follows these conventions:\n#{LanguageProfile.conventions_block(profile)}\n"

    system = """
    You pick today's grammar focus for a native #{native} speaker learning #{profile.prompt_name} at CEFR level #{level}.

    #{task}
    Respond with:
    - "category": the category that fits the point best
    - "title": the point in at most 6 words, in #{feedback_lang}
    - "body": the rule in one sentence of at most 20 words, in #{feedback_lang}, then one short example sentence in #{profile.prompt_name}
    #{conventions}
    """

    with {:ok, client} <- AI.client(),
         {:ok, focus} <-
           AI.chat(
             client,
             [
               system: system,
               messages: [%{role: "user", content: "Write today's focus."}],
               schema: schema(),
               purpose: "focus",
               max_tokens: 1024
             ] ++ Keyword.take(opts, [:model, :effort])
           ) do
      {:ok, normalize(focus, category)}
    end
  end

  # Today's category wins over the model's, so the rotation in `Focus.choose/3` holds. On a
  # cold start the model's pick becomes the category.
  @doc false
  def normalize(%{"category" => picked, "title" => title, "body" => body}, category) do
    %{
      "category" => category || picked,
      "title" => String.trim(title),
      "body" => String.trim(body)
    }
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "category" => %{"type" => "string", "enum" => Proofreader.categories()},
        "title" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      },
      "required" => ["category", "title", "body"],
      "additionalProperties" => false
    }
  end
end
