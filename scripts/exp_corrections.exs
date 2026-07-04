# Experiment harness: compare correction OUTPUT FORMATS + models, head-to-head.
#
#   mix run scripts/exp_corrections.exs [provider:model]
#   THINKING=on|off  STRAT=diff_notes,diff_full,json,baseline  mix run scripts/exp_corrections.exs zai:glm-5.2
#
# The finding that drives these strategies: the model's fully-corrected REWRITE is reliable;
# its hand-picked before/after spans (and hand-written [[..]] markers) are not. So the
# structured strategies below never ask the model to place spans — WE compute spans with a
# deterministic word diff of original↔corrected and only take type/explanation from the model.
#
#   baseline   — current inline-marker prompt (model authors [[before||after||type||expl]])
#   json       — model returns only a corrections list (no full text); we locate each `before`
#   diff_notes — model returns {corrected, notes:[{type,explanation}]}; spans from diff, notes by order
#   diff_full  — model returns {corrected, corrections:[{before,after,type,explanation}]};
#                spans from diff, metadata matched to each diff region by string
#
# Measures: format failures (garble / unlocatable / self-inconsistent), misses (a mistake left
# uncorrected), false positives (a clean sentence "corrected"), and OUTPUT tokens (what costs).

alias DailyOutput.{Repo, AI}
alias DailyOutput.AI.LanguageProfile
alias DailyOutput.AI.RewriteDiff
import Ecto.Query

model_spec = System.argv() |> Enum.find(&(&1 =~ ~r/^[a-z_]+:.+/))

if model_spec do
  # A model arg means "benchmark THIS model everywhere". Clear the per-purpose overrides too,
  # or :ai_model_overrides (proofread/proofread_message → GLM by default) silently shadows the
  # arg — resolve_model checks the override before :ai_model, so without this the benchmark
  # would run GLM no matter what spec you pass.
  Application.put_env(:daily_output, :ai_model, model_spec)
  Application.put_env(:daily_output, :ai_model_overrides, %{})
end

case System.get_env("THINKING") do
  t when t in ["on", "enabled", "1"] -> Application.put_env(:daily_output, :ai_thinking, %{type: "enabled"})
  t when t in ["off", "disabled", "0"] -> Application.put_env(:daily_output, :ai_thinking, %{type: "disabled"})
  _ -> :ok
end

want = (System.get_env("STRAT") || "diff_full,two_call") |> String.split(",", trim: true)

profile = LanguageProfile.resolve("de")
categories = AI.Proofreader.categories()
feedback_lang = profile.prompt_name
conventions = profile.conventions |> Enum.map(&"- #{&1}") |> Enum.join("\n")

# ── Deterministic, case-sensitive word diff → ordered change regions ─────────
# (Flashcards.Diff folds case, which German capitalization needs to keep, so a small
#  purpose-built diff here. Groups each del-run+ins-run between anchors into one region.)
defmodule ExpDiff do
  def tokens(t), do: String.split(t, ~r/\s+/, trim: true)

  # {annotated_text_with_bare_markers, [%{before, after}]} in reading order.
  def build(orig, corr) do
    a = tokens(orig)
    b = tokens(corr)
    ops = ops(a, b)

    {parts, cur} =
      Enum.reduce(ops, {[], nil}, fn
        {:eq, w}, {parts, cur} -> {flush(parts, cur) ++ [w], nil}
        {:del, w}, {parts, cur} -> {parts, add(cur, :b, w)}
        {:ins, w}, {parts, cur} -> {parts, add(cur, :a, w)}
      end)

    parts = flush(parts, cur)
    regions = for {:region, bf, af} <- parts, do: %{before: bf, after: af}
    {render(parts), regions}
  end

  defp add(nil, side, w), do: add(%{b: [], a: []}, side, w)
  defp add(cur, :b, w), do: %{cur | b: cur.b ++ [w]}
  defp add(cur, :a, w), do: %{cur | a: cur.a ++ [w]}

  defp flush(parts, nil), do: parts
  defp flush(parts, cur), do: parts ++ [{:region, Enum.join(cur.b, " "), Enum.join(cur.a, " ")}]

  defp render(parts) do
    parts
    |> Enum.map(fn
      {:region, bf, af} -> "[[#{bf}||#{af}]]"
      w -> w
    end)
    |> Enum.join(" ")
    # keep insertion/deletion markers touching their neighbours cleanly
    |> String.replace(" [[", " [[")
  end

  # emit {:eq|:del|:ins, word} in order (dels before inss within each gap)
  defp ops(a, b) do
    {ai, bi} = lcs(List.to_tuple(a), List.to_tuple(b))
    pairs = Enum.zip(ai, bi)

    {ops, i, j} =
      Enum.reduce(pairs, {[], 0, 0}, fn {mi, mj}, {ops, i, j} ->
        ops = ops ++ dels(a, i, mi) ++ inss(b, j, mj) ++ [{:eq, Enum.at(a, mi)}]
        {ops, mi + 1, mj + 1}
      end)

    ops ++ dels(a, i, length(a)) ++ inss(b, j, length(b))
  end

  defp dels(a, from, to), do: for(k <- from..(to - 1)//1, do: {:del, Enum.at(a, k)})
  defp inss(b, from, to), do: for(k <- from..(to - 1)//1, do: {:ins, Enum.at(b, k)})

  defp lcs(a, b) do
    n = tuple_size(a)
    m = tuple_size(b)

    dp =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        acc ->
          v =
            cond do
              i == n or j == m -> 0
              elem(a, i) == elem(b, j) -> 1 + Map.get(acc, {i + 1, j + 1}, 0)
              true -> max(Map.get(acc, {i + 1, j}, 0), Map.get(acc, {i, j + 1}, 0))
            end

          Map.put(acc, {i, j}, v)
      end

    back(a, b, n, m, dp, 0, 0, [], [])
  end

  defp back(_a, _b, n, m, _dp, i, j, xa, xb) when i == n or j == m, do: {Enum.reverse(xa), Enum.reverse(xb)}

  defp back(a, b, n, m, dp, i, j, xa, xb) do
    cond do
      elem(a, i) == elem(b, j) -> back(a, b, n, m, dp, i + 1, j + 1, [i | xa], [j | xb])
      Map.get(dp, {i + 1, j}, 0) >= Map.get(dp, {i, j + 1}, 0) -> back(a, b, n, m, dp, i + 1, j, xa, xb)
      true -> back(a, b, n, m, dp, i, j + 1, xa, xb)
    end
  end
end

# ── Shared instruction: WHAT to correct (mirrors Proofreader.correction_goal) ─
goal = """
You are a #{profile.prompt_name} teacher correcting one message a English speaker (CEFR level B2) just sent in a casual chat.

Language-specific conventions:
#{conventions}

Correct two kinds of things, equally important:
- Outright errors — grammar, agreement, case, gender, word order, verb forms, spelling, wrong words.
- Unnatural phrasing — understandable but not what a native says: a literal translation from English, an awkward word choice, a stiff preposition or word order. Do NOT skip these; they are what the student most needs.

This is spoken-style chat: don't flag informal register or contractions that are normal in speech. Tailor to B2: mark what helps them progress, don't nitpick, don't flag things above their level, leave anything already correct and natural untouched, never invent errors.
"""

meta_desc = "Every change needs a `type` (one of: #{Enum.join(categories, ", ")}) and a 5-10 word `explanation` in #{feedback_lang}."

# ── Tool schemas ─────────────────────────────────────────────────────────────
corr_item = %{
  "type" => "object",
  "properties" => %{
    "before" => %{"type" => "string", "description" => "the student's exact original words that change (verbatim)"},
    "after" => %{"type" => "string", "description" => "what they become"},
    "type" => %{"type" => "string", "enum" => categories},
    "explanation" => %{"type" => "string", "description" => "5-10 words in #{feedback_lang}"}
  },
  "required" => ["before", "after", "type", "explanation"]
}

note_item = %{
  "type" => "object",
  "properties" => %{
    "type" => %{"type" => "string", "enum" => categories},
    "explanation" => %{"type" => "string", "description" => "5-10 words in #{feedback_lang}"}
  },
  "required" => ["type", "explanation"]
}

tools = %{
  json: %{
    name: "report",
    description: "Report each correction. Empty list if the message is already correct and natural.",
    input_schema: %{"type" => "object", "properties" => %{"corrections" => %{"type" => "array", "items" => corr_item}}, "required" => ["corrections"]}
  },
  diff_notes: %{
    name: "report",
    description: "Rewrite the message correctly, then explain each change.",
    input_schema: %{"type" => "object", "properties" => %{
      "corrected" => %{"type" => "string", "description" => "the message rewritten exactly as a native would say it — change only what must change, keep everything else identical. Unchanged if already correct."},
      "notes" => %{"type" => "array", "items" => note_item, "description" => "one entry per change, in the order the changes appear"}
    }, "required" => ["corrected", "notes"]}
  },
  diff_full: %{
    name: "report",
    description: "Rewrite the message correctly, then list each change.",
    input_schema: %{"type" => "object", "properties" => %{
      "corrected" => %{"type" => "string", "description" => "the message rewritten exactly as a native would say it — change only what must change, keep everything else identical. Unchanged if already correct."},
      "corrections" => %{"type" => "array", "items" => corr_item}
    }, "required" => ["corrected", "corrections"]}
  },
  # two-call: call 1 only rewrites; the diff (code) decides the change list; call 2 labels them.
  rewrite_only: %{
    name: "report",
    description: "Return the corrected rewrite of the message.",
    input_schema: %{"type" => "object", "properties" => %{
      "corrected" => %{"type" => "string", "description" => "the message rewritten exactly as a native would say it — change only what must change, keep everything else (and all line breaks) identical. Unchanged if already correct."}
    }, "required" => ["corrected"]}
  },
  explain: %{
    name: "report",
    description: "Explain each listed change, in order.",
    input_schema: %{"type" => "object", "properties" => %{
      "explanations" => %{"type" => "array", "items" => note_item, "description" => "one entry per listed change, same order"}
    }, "required" => ["explanations"]}
  }
}

systems = %{
  json: goal <> "\nUse the `report` tool. " <> meta_desc <> " Quote the smallest span that fixes each error in `before`; for a word-order fix quote the whole moving span.",
  diff_notes: goal <> "\nUse the `report` tool: write the fully `corrected` message, then one `notes` entry per change in order. " <> meta_desc,
  diff_full: goal <> "\nUse the `report` tool: write the fully `corrected` message, then list each change in `corrections`. " <> meta_desc,
  rewrite_only: goal <> "\nUse the `report` tool: return ONLY the fully `corrected` message — the student's text rewritten the way a native speaker would actually say it. Fix EVERY error and EVERY unnatural or non-idiomatic phrasing, however small; be thorough, don't let anything through. Leave a part unchanged only when it is already fully correct and natural.",
  explain: goal <> "\nYou are given the student's original text, its corrected version, and a numbered list of the changes. Use the `report` tool to return one `explanations` entry per change, IN THE SAME ORDER, each a {type, explanation}. " <> meta_desc <> " Do not add or skip any."
}

# ── Marker builders per strategy ─────────────────────────────────────────────
norm = fn s -> s |> to_string() |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim() end

# json: locate each `before` in the original, left to right; count unlocatable.
build_json = fn original, corrections ->
  {out, cursor, bad} =
    Enum.reduce(corrections, {"", 0, 0}, fn c, {out, cursor, bad} ->
      bf = to_string(c["before"] || "")
      seg = "[[#{bf}||#{c["after"]}||#{c["type"]}||#{c["explanation"]}]]"
      rest = String.slice(original, cursor, String.length(original))

      cond do
        bf == "" -> {out <> seg, cursor, bad}
        (m = :binary.match(rest, bf)) != :nomatch ->
          {p, l} = m
          {out <> String.slice(rest, 0, p) <> seg, cursor + p + l, bad}
        true -> {out, cursor, bad + 1}
      end
    end)

  {String.trim(out <> String.slice(original, cursor, String.length(original))), bad, length(corrections)}
end

# diff strategies: spans from diff(original, corrected); attach type/explanation per region.
# Moves (a word deleted here, inserted there) split into two regions; the delete-half carries
# no explanation of its own — it shares the insert-half's (that's correct UX: strike here,
# green + tooltip there). So a pure-deletion region whose word reappears as an insertion is
# not "under-explained".
attach = fn bare, regions, metas_for_region ->
  regions
  |> Enum.with_index()
  |> Enum.reduce(bare, fn {r, i}, acc ->
    meta = Enum.at(metas_for_region, i) || %{"type" => "other", "explanation" => ""}
    from = "[[#{r.before}||#{r.after}]]"
    to = "[[#{r.before}||#{r.after}||#{meta["type"]}||#{meta["explanation"]}]]"
    String.replace(acc, from, to, global: false)
  end)
end

# A marker is under-explained only if it's a replace/insert (not a pure deletion, and not the
# strike-half of a move) with an empty explanation.
under_explained = fn annotated, moved_words ->
  ~r/\[\[([\s\S]*?)\]\]/
  |> Regex.scan(annotated)
  |> Enum.count(fn [_, inner] ->
    case String.split(inner, "||", parts: 4) do
      [bf, af, _t, expl] ->
        String.trim(expl) == "" and af != "" and
          not MapSet.member?(moved_words, String.downcase(bf))

      _ -> false
    end
  end)
end

# match each diff region to the model correction whose after/before best matches (diff_full)
match_meta = fn regions, corrections ->
  {metas, _} =
    Enum.reduce(regions, {[], corrections}, fn r, {metas, pool} ->
      hit =
        Enum.find(pool, fn c -> norm.(c["after"]) == norm.(r.after) end) ||
          Enum.find(pool, fn c -> norm.(c["before"]) == norm.(r.before) end) ||
          List.first(pool)

      {metas ++ [hit], List.delete(pool, hit)}
    end)

  metas
end

# ── Analysis ─────────────────────────────────────────────────────────────────
mrx = ~r/\[\[([\s\S]*?)\]\]/
words = fn t -> t |> String.downcase() |> String.split(~r/\s+/, trim: true) end
reduce_before = fn at -> Regex.replace(mrx, at, fn _w, i -> i |> String.split("||") |> List.first() end) end

analyze = fn original, annotated, extra_reasons ->
  reasons = extra_reasons
  r = words.(reduce_before.(annotated))
  o = words.(original)
  reasons = if length(r) > length(o), do: ["garbled: +#{length(r) - length(o)} words" | reasons], else: reasons
  malformed = mrx |> Regex.scan(annotated) |> Enum.count(fn [_, i] -> length(String.split(i, "||")) < 2 end)
  if malformed > 0, do: ["#{malformed} malformed" | reasons], else: reasons
end

sentences = [
  {"Gestern ich habe in die Stadt gegangen und habe ein neues Buch gekauft.", :mistake},
  {"Manchmal vergesse ich, dass ich jede Woche zwei Stunden Deutsch hören bei der Chor Probe.", :mistake},
  {"In dem zweiten Video hat er erklärt, was wir machen in unserer Chorreise in Oktober nach Bremen.", :mistake},
  {"Aber heute habe ich zwei zehn-Minuten lang videos geschaut, von meinem Dirigent.", :mistake},
  {"Ich hoffe, dass sie von mir geliebt sich gefühlt haben.", :mistake},
  {"Die Kameras sind super aber die Face unlock ist nicht so gut.", :mistake},
  {"Ja natürlich grillieren wir immer Burgers in Amerika! Die Schweizer grillieren immer verschiedene Arten Würste.", :mistake},
  {"Im Sommer habe ich nie kalt.", :mistake},
  {"Ich habe einen Fehler gemacht und ich bin sorry.", :mistake},
  {"Hast du (ever?) etwas sehr ecklig probiert?", :mistake},
  {"Für Glace, mag ich sehr Schokolade.", :mistake},
  {"Manchmal etwas fruchtiges ist sehr erfrischend.", :mistake},
  {"Ich habe letztes Wochenende eine gute Zeit gehabt.", :idiomatic},
  {"Wenn es regnet, bin ich langweilig zu Hause.", :idiomatic},
  {"Ich habe zwanzig Minuten für den Bus gewartet.", :idiomatic},
  {"Das Wetter ist heute sehr schön und ich gehe spazieren.", :clean},
  {"Ich gehe heute Abend mit ein paar Freunden ins Kino.", :clean},
  {"Bin grad am Kochen, meld mich später bei dir.", :clean}
]

opts = [target_language: "de", native_language: "en", language_level: "B2", prompt_context: "", context_messages: []]
{:ok, client} = AI.client()

chat_once = fn system, tool, user_content ->
  AI.chat(client,
    system: system,
    messages: [%{role: "user", content: user_content}],
    tools: [tool],
    tool_choice: %{type: "tool", name: "report"},
    purpose: "proofread_message",
    max_tokens: 1024
  )
end

# z.ai occasionally drops the socket under rapid-fire calls; retry once so the benchmark
# isn't polluted by transient network errors (production makes one call per message).
chat_tool = fn system, tool, user_content ->
  result =
    case chat_once.(system, tool, user_content) do
      {:error, _} -> chat_once.(system, tool, user_content)
      ok -> ok
    end

  case result do
    {:ok, resp} -> {AI.tool_use(resp) || %{}, resp["usage"]["output_tokens"] || 0}
    {:error, e} -> {{:error, e}, 0}
  end
end

correct_prompt = fn original -> "The student just sent this message — correct only this message:\n\n#{original}" end
call = fn strat, original -> chat_tool.(systems[strat], tools[strat], correct_prompt.(original)) end

# Some models (Sonnet especially) return an array-typed tool field as a JSON STRING instead of
# a real list — same quirk production guards with Proofreader.decode_if_string. Coerce to a list
# so the harness doesn't crash mid-run (Enum on a BitString) and silently drop the whole model.
decode_list = fn
  v when is_list(v) -> v
  v when is_binary(v) ->
    case Jason.decode(v) do
      {:ok, l} when is_list(l) -> l
      {:ok, %{} = m} -> Enum.find_value(m, [], fn {_k, val} -> is_list(val) && val end)
      _ -> []
    end
  _ -> []
end

run = fn
  "baseline", original ->
    case AI.proofread_message(original, opts) do
      {:ok, fb} -> {fb["annotated_text"], length(fb["annotations"] || []), nil, analyze.(original, fb["annotated_text"], [])}
      {:error, e} -> {"(err)", 0, nil, ["error: #{inspect(e)}"]}
    end

  "json", original ->
    case call.(:json, original) do
      {{:error, e}, _} -> {"(err)", 0, 0, ["error: #{inspect(e)}"]}
      {input, tok} ->
        {annotated, bad, n} = build_json.(original, decode_list.(input["corrections"]))
        extra = if bad > 0, do: ["#{bad} unlocatable"], else: []
        {annotated, n, tok, analyze.(original, annotated, extra)}
    end

  "two_call", original ->
    case chat_tool.(systems[:rewrite_only], tools[:rewrite_only], correct_prompt.(original)) do
      {{:error, e}, _} -> {"(err)", 0, 0, ["error: #{inspect(e)}"]}
      {input1, tok1} ->
        corrected = to_string(input1["corrected"] || original)
        changes = RewriteDiff.changes(original, corrected)

        if changes == [] do
          {corrected, 0, tok1, []}
        else
          listing =
            changes
            |> Enum.with_index(1)
            |> Enum.map(fn {c, i} -> "#{i}. «#{c["before"]}» → «#{c["after"]}»" end)
            |> Enum.join("\n")

          user2 = "Student's original:\n#{original}\n\nCorrected:\n#{corrected}\n\nChanges made (explain each, in order):\n#{listing}"
          {input2, tok2} = chat_tool.(systems[:explain], tools[:explain], user2)
          expls = if is_map(input2), do: decode_list.(input2["explanations"]), else: []

          corrections =
            changes
            |> Enum.with_index()
            |> Enum.map(fn {c, i} ->
              e = Enum.at(expls, i) || %{}
              Map.merge(c, %{"type" => e["type"] || "other", "explanation" => e["explanation"] || ""})
            end)

          annotated = RewriteDiff.annotate(original, corrected, corrections)
          moved = for(c <- changes, c["before"] == "", into: MapSet.new(), do: String.downcase(c["after"]))
          gaps = under_explained.(annotated, moved)
          extra = if gaps > 0, do: ["#{gaps} under-explained"], else: []
          {annotated, length(changes), tok1 + tok2, analyze.(original, annotated, extra)}
        end
    end

  strat, original when strat in ["diff_notes", "diff_full"] ->
    case call.(String.to_atom(strat), original) do
      {{:error, e}, _} -> {"(err)", 0, 0, ["error: #{inspect(e)}"]}
      {input, tok} ->
        corrected = to_string(input["corrected"] || original)
        {bare, regions} = ExpDiff.build(original, corrected)

        metas =
          if strat == "diff_notes",
            do: decode_list.(input["notes"]),
            else: match_meta.(regions, decode_list.(input["corrections"]))

        annotated = attach.(bare, regions, metas)
        # moves: a deleted word that reappears as an insertion shares the insert-half's tooltip
        moved = for(r <- regions, r.before == "", into: MapSet.new(), do: String.downcase(r.after))
        gaps = under_explained.(annotated, moved)
        extra = if gaps > 0, do: ["#{gaps} under-explained"], else: []
        {annotated, length(regions), tok, analyze.(original, annotated, extra)}
    end
end

before_id = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0
IO.puts("model: #{Application.get_env(:daily_output, :ai_model) || "(auto Sonnet)"}   thinking: #{inspect(Application.get_env(:daily_output, :ai_thinking, %{type: "disabled"}))}\n")

for strat <- want do
  IO.puts("\n══════════════════ STRATEGY: #{strat} ══════════════════")
  t = Enum.reduce(sentences, %{fail: 0, miss: 0, fp: 0, tok: 0}, fn {orig, class}, acc ->
    {annotated, ncorr, tok, reasons} = run.(strat, orig)
    fail? = reasons != []
    miss? = class in [:mistake, :idiomatic] and ncorr == 0
    fp? = class == :clean and ncorr > 0
    flag = cond do
      fail? -> "✗"
      miss? -> "⚠MISS"
      fp? -> "⚠FP"
      true -> "✓"
    end
    IO.puts("\n#{flag} [#{class}] #{orig}")
    IO.puts("   → #{annotated}")
    IO.puts("   (#{ncorr} corr#{if tok, do: ", #{tok} tok", else: ""})")
    Enum.each(reasons, &IO.puts("   ! #{&1}"))
    %{fail: acc.fail + (if(fail?, do: 1, else: 0)), miss: acc.miss + (if(miss?, do: 1, else: 0)), fp: acc.fp + (if(fp?, do: 1, else: 0)), tok: acc.tok + (tok || 0)}
  end)
  IO.puts("\n── #{strat}: #{t.fail} fail · #{t.miss} miss · #{t.fp} false-pos · #{t.tok} out-tokens ──")
end

{deleted, _} = Repo.delete_all(from u in "api_usages", where: u.id > ^before_id)
IO.puts("\n(cleaned #{deleted} api_usages rows)")
