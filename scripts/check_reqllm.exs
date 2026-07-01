# Live end-to-end check for the ReqLLM swap (replaces the anthropix transport).
#
#   mix run scripts/check_reqllm.exs
#
# Makes real API calls, then deletes the api_usages rows it creates so your stats stay clean.
# Verifies the three things a compile + unit tests can't:
#   [1] a plain (no-tools) call succeeds with thinking DISABLED — no 400, and output tokens
#       land in the low (non-thinking) range instead of the ~1000+ we saw when sonnet-5
#       thought by default;
#   [2] the forced-tool path still round-trips — the model's tool_use is decoded back into
#       feedback (annotated_text + commentary), proving ReqLLM forwards our Anthropic tool maps;
#   [3] which model discovery actually selected.

alias DailyOutput.{Repo, AI}
import Ecto.Query

# Optionally benchmark a specific model: pass a "provider:model" spec, e.g.
#   mix run scripts/check_reqllm.exs zai:glm-5.2
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

start_id = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0

usage_since = fn id ->
  Repo.all(
    from u in "api_usages",
      where: u.id > ^id,
      select: {u.model, u.input_tokens, u.output_tokens}
  )
end

run = fn label, fun ->
  before = Repo.aggregate(from(u in "api_usages"), :max, :id) || 0
  {fun.(), usage_since.(before), label}
end

active_model = Application.get_env(:daily_output, :ai_model) || "(auto-discover latest Anthropic Sonnet)"
thinking = Application.get_env(:daily_output, :ai_thinking, %{type: "disabled"})
IO.puts("=== ReqLLM live check ===\nmodel: #{active_model}\nthinking: #{inspect(thinking)}\n")

# [1] Plain path — the frequent, previously-expensive one. Thinking must be OFF.
{r1, rows1, _} =
  run.("proofread_message", fn ->
    AI.proofread_message("Gestern ich habe in die Stadt gegangen.",
      target_language: "de",
      native_language: "en",
      language_level: "B2"
    )
  end)

case r1 do
  {:ok, fb} ->
    IO.puts("[1] proofread_message  ✓ no error")
    IO.puts("    corrected: #{fb["annotated_text"]}")

    Enum.each(rows1, fn {m, i, o} ->
      verdict = if o > 700, do: "⚠ HIGH — thinking may still be ON", else: "✓ low — thinking off"
      IO.puts("    model=#{m}  in=#{i}  out=#{o}  #{verdict}")
    end)

  {:error, %{status: 400} = e} ->
    IO.puts("[1] proofread_message  ✗ 400 from the API")
    IO.inspect(e, label: "    error")

    IO.puts(
      "    → likely: this model rejects thinking:{type:\"disabled\"}.\n" <>
        "      Set `config :daily_output, :ai_thinking, false` (omit the field) and pin a non-thinking model."
    )

  {:error, e} ->
    IO.puts("[1] proofread_message  ✗ FAILED")
    IO.inspect(e, label: "    error")
end

# [2] Forced-tool path — verifies our Anthropic tool maps + tool_use decoding survive ReqLLM.
{r2, rows2, _} =
  run.("proofread", fn ->
    AI.proofread("Ich habe gestern in die Stadt gegangen. Es war ein schöner Tag.",
      target_language: "de",
      native_language: "en",
      language_level: "B2",
      prompt_context: "",
      focus_topic: nil
    )
  end)

case r2 do
  {:ok, fb} ->
    ok? =
      is_binary(fb["annotated_text"]) and fb["annotated_text"] != "" and is_list(fb["commentary"])

    IO.puts("\n[2] proofread (tool_use round-trip)  #{if ok?, do: "✓ decoded tool input", else: "⚠ empty/odd shape"}")
    IO.puts("    annotated: #{String.slice(fb["annotated_text"] || "", 0, 120)}")
    IO.puts("    commentary entries: #{length(fb["commentary"] || [])}")
    Enum.each(rows2, fn {m, i, o} -> IO.puts("    model=#{m}  in=#{i}  out=#{o}") end)

  {:error, e} ->
    IO.puts("\n[2] proofread (tool_use round-trip)  ✗ FAILED")
    IO.inspect(e, label: "    error")
end

{deleted, _} = Repo.delete_all(from u in "api_usages", where: u.id > ^start_id)
IO.puts("\n(cleaned up #{deleted} api_usages rows created by this run)")
