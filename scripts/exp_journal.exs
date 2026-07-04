# Journal-path proofread A/B: runs AI.proofread/2 (the long, multi-paragraph journal path —
# full rewrite + commentary + focus_result) on the latest real dev entry, across models,
# head-to-head. The chat path is already covered by exp_corrections.exs; this one exercises
# the higher-stakes journal proofread the cost complaint is about.
#
#   mix run scripts/exp_journal.exs                              # GLM 5.2 vs Sonnet 4.6
#   mix run scripts/exp_journal.exs zai:glm-5.2 anthropic:claude-sonnet-4-6
#
# Prints the annotated rewrite, each correction, the commentary, the focus_result, and the
# real OUTPUT tokens billed (from api_usages), then deletes the rows it created.

alias DailyOutput.{Repo, AI}
import Ecto.Query

models =
  case System.argv() |> Enum.filter(&(&1 =~ ~r/^[a-z_]+:.+/)) do
    [] -> ["zai:glm-5.2", "anthropic:claude-sonnet-4-6"]
    given -> given
  end

# Clear per-purpose overrides so the model we set per-iteration actually governs the
# "proofread" call — resolve_model checks :ai_model_overrides (proofread → GLM) before
# :ai_model, so without this the loop would run GLM for every "model".
Application.put_env(:daily_output, :ai_model_overrides, %{})

body =
  Repo.one(
    from e in "entries",
      where: is_nil(e.deleted_at) and fragment("length(?)", e.body) > 300,
      order_by: [desc: e.id],
      limit: 1,
      select: e.body
  ) || raise "no journal entry found in dev DB"

opts = [
  target_language: "de",
  native_language: "en",
  language_level: "B2",
  prompt_context: "",
  # a focus concept so we also exercise focus_result on the journal path
  focus_topic: "Perfekt mit sein vs. haben"
]

marker = ~r/\[\[([\s\S]*?)\]\]/

IO.puts("entry (#{String.length(body)} chars):\n#{body}\n")

for spec <- models do
  Application.put_env(:daily_output, :ai_model, spec)
  before_id = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0

  IO.puts("\n══════════════════ #{spec} ══════════════════")

  case AI.proofread(body, opts) do
    {:ok, fb} ->
      at = fb["annotated_text"] || ""
      anns = fb["annotations"] || []
      n = marker |> Regex.scan(at) |> length()

      tokens =
        Repo.one(
          from u in "api_usages",
            where: u.id > ^before_id and u.purpose == "proofread",
            select: u.output_tokens
        ) || 0

      # line-break fidelity: the rewrite must keep the paragraph structure
      orig_blanks = body |> String.split("\n") |> Enum.count(&(&1 == ""))
      new_blanks = at |> String.split("\n") |> Enum.count(&(&1 == ""))

      IO.puts("→ #{at}\n")
      IO.puts("corrections (#{n} markers, #{length(anns)} annotations):")
      Enum.each(anns, fn a -> IO.puts("   • [#{a["category"]}] #{a["explanation"]}") end)

      IO.puts("\ncommentary:")
      Enum.each(fb["commentary"] || [], fn c -> IO.puts("   • [#{c["type"]}] #{c["text"]}") end)

      case fb["focus_result"] do
        %{} = fr -> IO.puts("\nfocus_result: used=#{fr["used"]} correct=#{fr["correct"]} — #{fr["comment"]}")
        _ -> IO.puts("\nfocus_result: (none)")
      end

      IO.puts("\n── #{spec}: #{n} corrections · #{length(fb["commentary"] || [])} commentary · #{tokens} out-tokens · blanks #{orig_blanks}→#{new_blanks} ──")

    {:error, e} ->
      IO.puts("✗ error: #{inspect(e)}")
  end

  {del, _} = Repo.delete_all(from u in "api_usages", where: u.id > ^before_id)
  IO.puts("(cleaned #{del} api_usages rows)")
end
