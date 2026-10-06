# Runs every AI purpose of the daily flow through the production functions and writes
# tmp/bench/<model>-<effort>.json for grading. Effort defaults to the model's production one.
#
#   mix run scripts/bench.exs <provider:model> [--effort none|low|medium|high]
#   mix run scripts/bench.exs openai:gpt-6.1-sol
#   mix run scripts/bench.exs openai:gpt-6-luna --effort low
#
# Fixtures are inline and each correction carries its expected fix. AI.chat records
# api_usages rows as usual; the run deletes the ones it created.

Logger.configure(level: :warning)

alias DailyOutput.{Activities, AI, Markers, Planner, Repo, Stats}
alias DailyOutput.AI.{ConversationPartner, FocusWriter, Proofreader, SessionStarter}
alias DailyOutput.Flashcards.Generator
import Ecto.Query

{parsed, args, _} = OptionParser.parse(System.argv(), strict: [effort: :string])

[spec] = args
[_provider, model_id] = String.split(spec, ":", parts: 2)
effort = Keyword.get(parsed, :effort, to_string(AI.effort(model_id)))
true = effort in ~w(none low medium high)
out_path = "tmp/bench/#{String.replace(model_id, "/", "_")}-#{effort}.json"

# Each kind of day's call mix.
day_mixes = %{
  conversation: %{
    "proofread_message" => 5,
    "conversation" => 6,
    "assessment" => 1,
    "flashcards" => 1,
    "starter" => 1,
    "focus" => 1
  },
  journal: %{"proofread" => 1, "flashcards" => 1, "starter" => 1, "focus" => 1}
}

# {sentence, expected fix}. The expected fix is one good answer, not the only one.
german = [
  {"Gestern ich habe in die Stadt gegangen und habe ein neues Buch gekauft.",
   "Gestern bin ich in die Stadt gegangen und habe ein neues Buch gekauft."},
  {"Manchmal vergesse ich, dass ich jede Woche zwei Stunden Deutsch hören bei der Chor Probe.",
   "Manchmal vergesse ich, dass ich jede Woche bei der Chorprobe zwei Stunden Deutsch höre."},
  {"In dem zweiten Video hat er erklärt, was wir machen in unserer Chorreise in Oktober nach Bremen.",
   "Im zweiten Video hat er erklärt, was wir auf unserer Chorreise im Oktober nach Bremen machen."},
  {"Aber heute habe ich zwei zehn-Minuten lang videos geschaut, von meinem Dirigent.",
   "Aber heute habe ich zwei zehnminütige Videos von meinem Dirigenten geschaut."},
  {"Ich hoffe, dass sie von mir geliebt sich gefühlt haben.",
   "Ich hoffe, dass sie sich von mir geliebt gefühlt haben."},
  {"Die Kameras sind super aber die Face unlock ist nicht so gut.",
   "Die Kameras sind super, aber die Gesichtserkennung ist nicht so gut."},
  {"Ja natürlich grillieren wir immer Burgers in Amerika! Die Schweizer grillieren immer verschiedene Arten Würste.",
   "Ja, natürlich grillieren wir in Amerika immer Burger! Die Schweizer grillieren immer verschiedene Wurstsorten."},
  {"Für Glace, mag ich sehr Schokolade.", "Bei Glace mag ich am liebsten Schokolade."},
  {"Manchmal etwas fruchtiges ist sehr erfrischend.",
   "Manchmal ist etwas Fruchtiges sehr erfrischend."},
  {"Im Sommer habe ich nie kalt.", "Im Sommer ist mir nie kalt."},
  {"Ich habe einen Fehler gemacht und ich bin sorry.",
   "Ich habe einen Fehler gemacht, und es tut mir leid."},
  {"Hast du (ever?) etwas sehr ecklig probiert?",
   "Hast du schon einmal etwas richtig Ekliges probiert?"},
  # Grammatical but unidiomatic: calques and false friends.
  {"Ich habe letztes Wochenende eine gute Zeit gehabt.",
   "Ich hatte letztes Wochenende viel Spass."},
  {"Wenn es regnet, bin ich langweilig zu Hause.",
   "Wenn es regnet, ist mir zu Hause langweilig."},
  {"Ich habe zwanzig Minuten für den Bus gewartet.",
   "Ich habe zwanzig Minuten auf den Bus gewartet."},
  # Already correct and natural: must stay unchanged.
  {"Das Wetter ist heute sehr schön und ich gehe spazieren.", :unchanged},
  {"Ich gehe heute Abend mit ein paar Freunden ins Kino.", :unchanged},
  {"Bin grad am Kochen, meld mich später bei dir.", :unchanged}
]

french = [
  {"Hier, j'ai allé au marché et j'ai acheté des pommes.",
   "Hier, je suis allé au marché et j'ai acheté des pommes."},
  {"Je suis très excité pour mes vacances.", "J'ai vraiment hâte d'être en vacances."},
  {"Il fait beaucoup de froid aujourd'hui.", "Il fait très froid aujourd'hui."},
  {"Je cherche pour mes clés depuis une heure.", "Je cherche mes clés depuis une heure."},
  {"On se retrouve devant la gare à huit heures ?", :unchanged}
]

japanese = [
  {"Kinō watashi wa tomodachi to eiga o mimasu.",
   "Kinō watashi wa tomodachi to eiga o mimashita."},
  {"Kono resutoran wa oishii to yasui desu.", "Kono resutoran wa oishikute yasui desu."},
  {"Watashi wa kōen ni sanpo shimashita.", "Watashi wa kōen de sanpo shimashita."},
  {"Toshokan de hon o yomimashita, soshite kōhī o nomimashita.",
   "Toshokan de hon o yonde, kōhī o nomimashita."},
  {"Ashita wa ame ga furu to omoimasu.", :unchanged}
]

# A 5-turn conversation: the partner's turns are fixed so every run sees the same input.
conversation = [
  %{role: "assistant", body: "Hoi! Was hast du am Wochenende gemacht?"},
  %{
    role: "user",
    body:
      "Am Samstag ich bin mit meiner Freundin nach Luzern gefahren. Es war sehr schön Wetter.",
    expected:
      "Am Samstag bin ich mit meiner Freundin nach Luzern gefahren. Es war sehr schönes Wetter."
  },
  %{role: "assistant", body: "Oh, Luzern ist wunderschön! Was habt ihr dort unternommen?"},
  %{
    role: "user",
    body: "Wir haben über die Kapellbrücke gelaufen und danach wir haben ein Fondue gegessen.",
    expected: "Wir sind über die Kapellbrücke gelaufen und danach haben wir ein Fondue gegessen."
  },
  %{role: "assistant", body: "Fondue im Sommer? Mutig! Wie hat es geschmeckt?"},
  %{
    role: "user",
    body: "Es war lecker, aber ich habe zu viel gegessen und danach ich war sehr müde.",
    expected: "Es war lecker, aber ich habe zu viel gegessen und danach war ich sehr müde."
  },
  %{role: "assistant", body: "Das kenne ich! Habt ihr am Sonntag dann etwas Ruhigeres gemacht?"},
  %{
    role: "user",
    body:
      "Am Sonntag wir haben zu Hause geblieben und einen Film geschaut, weil es hat geregnet.",
    expected:
      "Am Sonntag sind wir zu Hause geblieben und haben einen Film geschaut, weil es geregnet hat."
  },
  %{
    role: "assistant",
    body: "Bei Regen ist ein Filmtag perfekt. Welchen Film habt ihr geschaut?"
  },
  %{
    role: "user",
    body:
      "Wir haben einen alten Film von Hitchcock geschaut. Ich mag sehr seine Filme, weil sie sind spannend.",
    expected:
      "Wir haben einen alten Film von Hitchcock geschaut. Ich mag seine Filme sehr, weil sie spannend sind."
  }
]

conversation_focus = %{
  "category" => "verb",
  "title" => "Perfekt mit sein bei Bewegung",
  "body" =>
    "Verben der Bewegung und des Zustandswechsels bilden das Perfekt mit «sein». Wir sind nach Luzern gefahren."
}

journal = """
Letzte Woche ich habe endlich angefangen, jeden Morgen zu joggen. Am ersten Tag ich bin nur zehn Minuten gelaufen, weil ich war so müde. Aber jetzt es geht viel besser.

Wenn ich mehr Zeit hätte, ich würde auch am Abend trainieren. Mein Kollege hat mir gesagt, dass ich soll langsam anfangen, sonst ich werde mich verletzen. Ich denke, er hat recht. Nächste Woche ich will mit ihm zusammen laufen, wenn das Wetter ist gut.
"""

journal_expected = """
Letzte Woche habe ich endlich angefangen, jeden Morgen zu joggen. Am ersten Tag bin ich nur zehn Minuten gelaufen, weil ich so müde war. Aber jetzt geht es viel besser.

Wenn ich mehr Zeit hätte, würde ich auch am Abend trainieren. Mein Kollege hat mir gesagt, dass ich langsam anfangen soll, sonst verletze ich mich. Ich denke, er hat recht. Nächste Woche will ich mit ihm zusammen laufen, wenn das Wetter gut ist.
"""

journal_focus = %{
  "category" => "verb",
  "title" => "Konjunktiv II für Wünsche",
  "body" =>
    "Für Unwirkliches nimmst du «würde» + Infinitiv oder «hätte/wäre». Wenn ich mehr Zeit hätte, würde ich mehr lesen."
}

summary =
  "You told me about your Saturday in Lucerne with your girlfriend: the Chapel Bridge, fondue, and a rainy Sunday with a Hitchcock film."

# {label, kind, target, level, summary, angle, focus}
starters = [
  {"conversation-continuity", "conversation", "de", "B2", summary, "thread", conversation_focus},
  {"conversation-cold", "conversation", "de", "B2", nil, "what-if", journal_focus},
  {"journal-continuity", "journal", "de", "B2", summary, "story", conversation_focus},
  {"journal-cold", "journal", "de", "B2", nil, "explain-how", journal_focus},
  {"conversation-fr-cold", "conversation", "fr", "B1", nil, "plan",
   %{
     "category" => "verb",
     "title" => "Passé composé with être",
     "body" => "Verbs of movement take être in the passé composé. Je suis allé au marché."
   }}
]

defmodule Bench do
  def on_stop(_event, _measurements, meta, _config), do: send(self(), {:ai_call, meta})

  def drain(acc \\ []) do
    receive do
      {:ai_call, meta} -> drain([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def raw_output(%{response_payload: %{message: message}}) do
    text =
      (message[:content] || [])
      |> Enum.filter(&(&1[:type] == :text))
      |> Enum.map_join("", & &1[:text])

    if text == "", do: inspect(message[:tool_calls]), else: text
  end

  def raw_output(_meta), do: nil

  def status({:ok, _}), do: "ok"
  def status({:error, :unparsed}), do: "parse_miss"
  def status({:error, _}), do: "error"

  def avg([]), do: 0
  def avg(values), do: Enum.sum(values) / length(values)
end

Application.put_env(:req_llm, :telemetry, payloads: :raw)
:telemetry.attach("bench", [:req_llm, :request, :stop], &Bench.on_stop/4, nil)

opts = fn target, level ->
  [
    target_language: target,
    native_language: "en",
    language_level: level,
    about_you: "",
    model: spec,
    effort: String.to_atom(effort)
  ]
end

run = fn purpose, label, input, expected, fun ->
  IO.write("#{purpose} · #{label} … ")

  {micros, result} =
    :timer.tc(fn ->
      try do
        fun.()
      rescue
        e -> {:error, {:crash, Exception.message(e)}}
      end
    end)

  calls = Bench.drain()
  tokens = Enum.map(calls, &(get_in(&1, [:usage, :tokens]) || %{}))
  sum = fn key -> tokens |> Enum.map(&(&1[key] || 0)) |> Enum.sum() end

  input_tokens = sum.(:input_tokens)
  output_tokens = sum.(:output_tokens)

  cost = Stats.cost(model_id, input_tokens, output_tokens, sum.(:cached_tokens))

  status = Bench.status(result)
  IO.puts("#{status} #{div(micros, 1000)}ms")

  %{
    purpose: purpose,
    label: label,
    input: input,
    expected: expected,
    status: status,
    error: if(status == "ok", do: nil, else: inspect(elem(result, 1))),
    raw_output: calls |> Enum.map(&Bench.raw_output/1) |> Enum.join("\n---\n"),
    parsed: if(status == "ok", do: elem(result, 1)),
    latency_ms: div(micros, 1000),
    input_tokens: input_tokens,
    output_tokens: output_tokens,
    # Part of output_tokens.
    reasoning_tokens: sum.(:reasoning_tokens),
    cost: cost
  }
end

before_id = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0
IO.puts("bench #{spec} effort=#{effort}\n")

correction_cases =
  for {set, target, level} <- [{german, "de", "B2"}, {french, "fr", "B1"}, {japanese, "ja", "B1"}],
      {{text, expected}, i} <- Enum.with_index(set, 1) do
    run.("proofread_message", "#{target}-#{i}", text, expected, fn ->
      Proofreader.proofread_message(text, opts.(target, level))
    end)
  end

# Each conversation turn is corrected in context, like the chat does, and the partner replies.
{conversation_cases, feedback_by_body} =
  conversation
  |> Enum.with_index()
  |> Enum.filter(fn {msg, _} -> msg.role == "user" end)
  |> Enum.map(fn {msg, i} ->
    prior = Enum.map(Enum.take(conversation, i), &Map.take(&1, [:role, :body]))
    turn = div(i + 1, 2)

    correction =
      run.("proofread_message", "conversation-#{turn}", msg.body, msg.expected, fn ->
        Proofreader.proofread_message(msg.body, opts.("de", "B2") ++ [context_messages: prior])
      end)

    history = prior ++ [Map.take(msg, [:role, :body])]

    # The reply to the 5th message wraps up, as Today.reply/1 does.
    reply =
      run.("conversation", "reply-#{turn}", history, nil, fn ->
        ConversationPartner.respond(history, opts.("de", "B2") ++ [wrap_up: turn == 5])
      end)

    {[correction, reply], {msg.body, correction.parsed}}
  end)
  |> Enum.unzip()

feedback_by_body = Map.new(feedback_by_body)

full_transcript =
  Enum.map(conversation, &%{role: &1.role, body: &1.body, feedback: feedback_by_body[&1.body]})

assessment =
  run.("assessment", "conversation", %{focus: conversation_focus}, nil, fn ->
    Proofreader.assess_conversation(
      full_transcript,
      opts.("de", "B2") ++ [focus: conversation_focus]
    )
  end)

# Built from the conversation's corrections the same way Flashcards.ingest/1 does.
feedbacks = for %{feedback: %{"annotated_text" => annotated}} <- full_transcript, do: annotated
mistakes = Enum.flat_map(feedbacks, &(&1 |> Markers.parse() |> Markers.substantive()))
corrected_text = feedbacks |> Enum.flat_map(&Markers.mistake_sentences/1) |> Enum.join("\n")

flashcards =
  run.("flashcards", "conversation", %{corrected: corrected_text, mistakes: mistakes}, nil, fn ->
    Generator.generate(corrected_text, mistakes, opts.("de", "B2"))
  end)

journal_case =
  run.("proofread", "journal", journal, journal_expected, fn ->
    Proofreader.proofread(journal, opts.("de", "B2") ++ [focus: journal_focus])
  end)

starter_cases =
  for {label, kind, target, level, summary, angle, focus} <- starters do
    input = %{kind: kind, summary: summary, angle: angle, focus: focus}

    run.("starter", label, input, nil, fn ->
      SessionStarter.start(
        kind,
        opts.(target, level) ++
          [summary: summary, angle: Planner.angle_instruction(angle), focus: focus]
      )
    end)
  end

# The same mistake list Today.prepare/1 builds, from this run's conversation corrections.
word_order =
  [%{feedback: nil, messages: full_transcript}]
  |> Activities.corrections()
  |> Enum.filter(&(&1.category == "word-order"))

focus_cases =
  for {label, target, level, category, mistakes} <- [
        {"de-mistakes", "de", "B2", "word-order", word_order},
        {"de-cold", "de", "B2", nil, []},
        {"ja-cold", "ja", "B1", nil, []}
      ] do
    run.("focus", label, %{category: category, mistakes: mistakes}, nil, fn ->
      FocusWriter.write(category, mistakes, opts.(target, level))
    end)
  end

cases =
  correction_cases ++
    List.flatten(conversation_cases) ++
    [assessment, flashcards, journal_case] ++ starter_cases ++ focus_cases

purposes =
  cases
  |> Enum.group_by(& &1.purpose)
  |> Map.new(fn {purpose, rows} ->
    {purpose,
     %{
       cases: length(rows),
       parse_misses: Enum.count(rows, &(&1.status == "parse_miss")),
       errors: Enum.count(rows, &(&1.status == "error")),
       avg_latency_ms: round(Bench.avg(Enum.map(rows, & &1.latency_ms))),
       avg_input_tokens: round(Bench.avg(Enum.map(rows, & &1.input_tokens))),
       avg_output_tokens: round(Bench.avg(Enum.map(rows, & &1.output_tokens))),
       max_output_tokens: rows |> Enum.map(& &1.output_tokens) |> Enum.max(),
       avg_reasoning_tokens: round(Bench.avg(Enum.map(rows, & &1.reasoning_tokens))),
       avg_cost: Bench.avg(Enum.map(rows, & &1.cost))
     }}
  end)

day_costs =
  Map.new(day_mixes, fn {day, mix} ->
    {day, Enum.reduce(mix, 0.0, fn {purpose, n}, acc -> acc + n * purposes[purpose].avg_cost end)}
  end)

report = %{
  model: spec,
  effort: effort,
  run_at: DateTime.utc_now(),
  day_cost: %{usd: day_costs, mix: day_mixes},
  purposes: purposes,
  cases: cases
}

File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, Jason.encode!(report, pretty: true))

{deleted, _} = Repo.delete_all(from(u in "api_usages", where: u.id > ^before_id))

IO.puts("\n#{String.pad_trailing("purpose", 18)} cases  miss  err  avg ms  max out   avg $")

for {purpose, s} <- Enum.sort(purposes) do
  IO.puts(
    "#{String.pad_trailing(purpose, 18)} #{String.pad_leading("#{s.cases}", 5)} #{String.pad_leading("#{s.parse_misses}", 5)} #{String.pad_leading("#{s.errors}", 4)} #{String.pad_leading("#{s.avg_latency_ms}", 7)} #{String.pad_leading("#{s.max_output_tokens}", 8)}  #{:erlang.float_to_binary(s.avg_cost * 1.0, decimals: 5)}"
  )
end

IO.puts("")
for {day, usd} <- day_costs, do: IO.puts("#{day} day: $#{:erlang.float_to_binary(usd, decimals: 4)}")
IO.puts("wrote #{out_path} (removed #{deleted} api_usages rows)")
