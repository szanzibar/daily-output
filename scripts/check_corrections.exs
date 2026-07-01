# On-demand sanity check for the proofreading prompt + marker parsing.
#
#   mix run scripts/check_corrections.exs            # built-in sample sentences
#   mix run scripts/check_corrections.exs --entry    # also run the latest journal entry
#
# Makes real API calls, then deletes the api_usages rows it creates so your stats stay clean.
# The samples cover three things: outright learner mistakes (word order, Perfekt mit sein/haben,
# compound nouns, capitalization, …) that used to garble; grammatical-but-unidiomatic phrasing
# (calques, false friends, wrong prepositions) the corrector must now catch; and already-correct
# natural sentences that must stay clean (balance — no invented nitpicks). Each result is flagged:
#   ✓ clean   ·   ⚠ no corrections (model missed, or guard fell back)   ·   ✗ garbled/duplicated.
# For ⚠/✗, eyeball whether it's the right call: on a natural sentence ⚠ is correct, not a miss.

alias DailyOutput.{Repo, AI}
import Ecto.Query

# Optionally benchmark a specific model: pass a "provider:model" spec, e.g.
#   mix run scripts/check_corrections.exs zai:glm-5.2
System.argv()
|> Enum.find(&(&1 =~ ~r/^[a-z_]+:.+/))
|> case do
  nil -> :ok
  spec -> Application.put_env(:daily_output, :ai_model, spec)
end

# Override thinking for this run: THINKING=on|off (default: whatever config says)
case System.get_env("THINKING") do
  t when t in ["on", "enabled", "1"] ->
    Application.put_env(:daily_output, :ai_thinking, %{type: "enabled"})

  t when t in ["off", "disabled", "0"] ->
    Application.put_env(:daily_output, :ai_thinking, %{type: "disabled"})

  _ ->
    :ok
end

IO.puts("model: #{Application.get_env(:daily_output, :ai_model) || "(auto-discover latest Anthropic Sonnet)"}")
IO.puts("thinking: #{inspect(Application.get_env(:daily_output, :ai_thinking, %{type: "disabled"}))}\n")

opts = [
  target_language: "de",
  native_language: "en",
  language_level: "B2",
  prompt_context: "",
  context_messages: []
]

sentences = [
  "Gestern ich habe in die Stadt gegangen und habe ein neues Buch gekauft.",
  "Manchmal vergesse ich, dass ich jede Woche zwei Stunden Deutsch hören bei der Chor Probe.",
  "In dem zweiten Video hat er erklärt, was wir machen in unserer Chorreise in Oktober nach Bremen.",
  "Aber heute habe ich zwei zehn-Minuten lang videos geschaut, von meinem Dirigent.",
  "Ich hoffe, dass sie von mir geliebt sich gefühlt haben.",
  "Die Kameras sind super aber die Face unlock ist nicht so gut.",
  "Das Wetter ist heute sehr schön und ich gehe spazieren.",
  # should be two tiny markers (delete comma + insert «gerne»), not one wide rewrite
  "Für Glace, mag ich sehr Schokolade.",
  # watch: model tends to span the unchanged «etwas» too instead of only «fruchtiges»
  "Manchmal etwas fruchtiges ist sehr erfrischend.",
  # only «habe ich»→«ist mir» should be marked; «nie kalt» is unchanged and must stay outside
  "Im Sommer habe ich nie kalt.",
  # genuine whole-phrase replacement — every word changes, so one wide marker is right
  "Ich habe einen Fehler gemacht und ich bin sorry.",
  # English placeholder for an unknown word — should be translated, not ignored
  "Hast du (ever?) etwas sehr ecklig probiert?",
  # --- idiomatic / naturalness: grammatical, but a native wouldn't say it (the case the
  #     error-only prompt used to miss). These SHOULD now get a vocabulary/other correction. ---
  # calque of "have a good time" — grammatical; nudge toward natural phrasing
  "Ich habe letztes Wochenende eine gute Zeit gehabt.",
  # false friend: «langweilig» = boring, they mean bored → «mir ist langweilig»
  "Wenn es regnet, bin ich langweilig zu Hause.",
  # calque of "wait for" — wrong preposition, should be «auf den Bus»
  "Ich habe zwanzig Minuten für den Bus gewartet.",
  # --- balance: these are already correct AND natural — must stay clean, no invented nitpicks ---
  "Ich gehe heute Abend mit ein paar Freunden ins Kino.",
  # casual spoken register that is fine in chat (ellipsis, colloquial) — not errors to flag
  "Bin grad am Kochen, meld mich später bei dir."
]

marker = ~r/\[\[([\s\S]*?)\]\]/
words = fn t -> t |> String.downcase() |> String.split(~r/\s+/, trim: true) end

before = fn inner ->
  inner |> String.replace(~r/^\d+:/, "") |> String.split("||") |> List.first()
end

reduce = fn at -> Regex.replace(marker, at, fn _w, inner -> before.(inner) end) end

# returns {flag, reasons}
analyze = fn original, at, anns ->
  n_markers = marker |> Regex.scan(at) |> length()
  r = words.(reduce.(at))
  o = words.(original)
  reasons = []
  # reduced should never be LONGER than the original — extra words = duplication/garble/prose
  reasons =
    if length(r) > length(o),
      do: ["garbled: +#{length(r) - length(o)} extra words" | reasons],
      else: reasons

  # bad markers: fewer than 2 ||-fields
  bad =
    marker
    |> Regex.scan(at)
    |> Enum.count(fn [_, inner] -> length(String.split(inner, "||")) < 2 end)

  reasons = if bad > 0, do: ["#{bad} malformed marker(s)" | reasons], else: reasons

  flag =
    cond do
      reasons != [] -> "✗"
      n_markers == 0 and at == original and anns == [] -> "⚠ no corrections"
      true -> "✓"
    end

  {flag, reasons}
end

run = fn original, fb ->
  at = fb["annotated_text"]
  anns = fb["annotations"] || []
  {flag, reasons} = analyze.(original, at, anns)
  IO.puts("\n#{flag}  #{original}")
  IO.puts("    → #{at}")
  Enum.each(anns, fn a -> IO.puts("       • [#{a["category"]}] #{a["explanation"]}") end)
  Enum.each(reasons, fn rsn -> IO.puts("       ! #{rsn}") end)
end

before_id = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0

IO.puts("=== chat corrections (proofread_message) ===")

for s <- sentences do
  case AI.proofread_message(s, opts) do
    {:ok, fb} -> run.(s, fb)
    {:error, e} -> IO.puts("\n✗  #{s}\n    error: #{inspect(e)}")
  end
end

if "--entry" in System.argv() do
  IO.puts("\n=== latest journal entry (proofread) ===")

  case Repo.one(
         from e in "entries",
           where: is_nil(e.deleted_at),
           order_by: [desc: e.id],
           limit: 1,
           select: e.body
       ) do
    nil ->
      IO.puts("(no entries)")

    body ->
      {:ok, fb} =
        AI.proofread(body,
          target_language: "de",
          native_language: "en",
          language_level: "B2",
          prompt_context: "",
          focus_topic: nil
        )

      run.(body, fb)
      orig_blanks = body |> String.split("\n") |> Enum.count(&(&1 == ""))
      new_blanks = fb["annotated_text"] |> String.split("\n") |> Enum.count(&(&1 == ""))
      IO.puts("       line breaks: original #{orig_blanks} blank lines, annotated #{new_blanks}")
  end
end

{deleted, _} = Repo.delete_all(from u in "api_usages", where: u.id > ^before_id)
IO.puts("\n(cleaned up #{deleted} api_usages rows created by this run)")
