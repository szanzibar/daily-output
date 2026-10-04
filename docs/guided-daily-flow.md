# Guided daily flow: overhaul plan

**Goal:** open the app and it tells you what to do. No setup screens, no choice lists,
no focus-pool curation. One activity plus a short card session passes the day; a second
activity is a bonus.

## The day

```
open app ─► today's activity, picked by the app (conversation or journal)
            · focus banner: today's grammar point, picked from your mistakes
            · conversation: ends automatically after your 5th message
            · journal: "Finish" appears at 5:00
            ▼
          results: inline corrections, focus graded (used? correct?), improvement panel
            ▼
          card practice: 20 flips, or until nothing is due (skipped if no cards yet)
            ▼
          done screen: streak, celebration, and one button for the bonus
            └─► bonus: the *other* activity → results → done (+1 streak freeze)
```

Reopening the app always resumes the exact step you're on. Same day: the same
conversation picks up where you stopped. Next day: a fresh conversation.

## Locked decisions

| Topic | Decision |
|---|---|
| Activity pick | Conversation-first: journal about 1 day in 3, never two journal days in a row. Seeded by date, so a refresh never changes the pick. No swap button. |
| Day passes | Activity complete **and** card session complete (or nothing due). |
| Bonus | Both activities in one day banks **1 freeze** (cap 3). Freezes bridge missed days, derived from history like today. No points system. |
| After done | Done screen with a single bonus offer. |
| Focus | Picked automatically from mistake frequency, rotated for freshness. Graded at the end, **never blocks** the day. The focus pool page and manual tip-saving are gone. |
| Flashcards | Fully automatic and part of the daily requirement. A "fix this card" action during practice is the escape hatch; the manage page stays but is rarely needed. |
| Pages kept | Today (`/`), History (read-only), Progress, Settings, Flashcard manage, About. |
| Models | Sonnet 5.5 (default) and GPT-5.6 Luna only, showing score + price. |
| Data | Nuke: one fresh migration, no backwards compatibility. |

## Architecture: deep modules

The web layer asks one question, "what now?", and the answer lives in one module. Every
rule sits behind a small interface, so steps can be reordered or swapped to experiment.

- **`DailyOutput.Today`** is the orchestrator. `next_step/0` returns
  `{:activity, activity} | :cards | :done`, creating today's activity on first call. The
  flow is one list (`@flow [:activity, :cards]`) plus the bonus rule. Tunables live here
  as module attributes: 5 minutes, 5 messages, 20 cards.
- **`DailyOutput.Planner`** (pure) holds the pickers, all taking explicit inputs and the
  date as a seed:
  - `activity_kind(recent_kinds, date)` picks conversation or journal.
  - `angle(recent_angles, focus, date)` picks a creative angle from a fixed list, e.g.
    pick up the thread, role-play a scenario, what-if, tell a story from your past, light
    debate, explain how to do something, plan something together, would-you-rather. Each
    angle names the grammar it naturally draws out (past tense → story, Konjunktiv II →
    what-if), so the picker prefers angles that fit today's focus and skips the last 3 used.
- **`DailyOutput.Focus`** picks today's grammar point.
  - Its pure core `choose(corrections, recent_focus_categories, date)` weights correction
    categories by recent frequency, skips the categories used in the last 2 days, and
    ignores spelling, punctuation, and other.
  - **`AI.FocusWriter`** turns that category plus your real recent mistakes in it into a
    concrete banner: the rule and one example. With no history yet (cold start), it picks
    a point suited to your level.
  - The result is stored on the activity, so it's one cheap call per day.
- **`DailyOutput.Streak`** (pure) is extracted from `FocusTopics.streak_info/0`. Input is
  per-day facts `%{date => %{activities: n, cards?: bool}}`; output is
  `%{count, freezes_available, today_status}`.
- **`DailyOutput.Activities`** is one context and one table for both kinds of activity
  (see Data model). It replaces `Journal` and `Conversations`.
- **`AI.SessionStarter`** is one generator for conversation openers and journal prompts,
  replacing `TopicGenerator` and `PromptGenerator`. Its inputs are the last activity's
  summary (continuity), the angle (variety), the focus (target grammar), and your profile.
  The output is one opener or prompt; there's never a list to choose from.
- **Wrap-up AI:** the conversation assessment and the journal proofread both also return a
  one-sentence `summary` (tomorrow's "where you left off") and a `focus_result`. The
  partner's reply to your 5th message is told to wrap up warmly.
- **Web:** each step is its own LiveView and only knows "when I'm done, navigate to `/`".
  `TodayLive` at `/` calls `Today.next_step/0`, then either redirects to the step or
  renders the done screen. Moving a step means editing `Today`, with no LiveView changes.

## Data model (one fresh migration)

- **`activities`**:
  - `kind` (`conversation` | `journal`)
  - `date`: the logical date, stamped via `Clock` at creation, so queries never do day-range math
  - `prompt`, `angle`
  - `focus`: map of `category`, `title`, `body`
  - `body` (journal text)
  - `feedback`, `summary`, `completed_at`
- **`messages`**: `activity_id`, `role`, `body`, `feedback` (per-message corrections, unchanged).
- **Kept unchanged:** flashcards tables, `push_subscriptions`, `vapid_keys`,
  `api_usages`, `time_logs`.
- **`settings`, slimmed to:** target and native language, level, "About you" (merges
  `topics` and `prompt_context`), UI language, theme, `ai_model`, `ai_provider`,
  timezone, and the reminder fields.
- **Gone:** `focus_topics`, versioning, soft delete, `timer_minutes`, `min_exchanges`,
  `flashcards_per_day`.

## Models

- **Sonnet 5.5** (default): score 83.4, $2 / $10 per M tokens.
- **GPT-5.6 Luna**: score 66.2, $0.20 / $1.20 per M tokens.
- Source: benchlm.ai, Oct 2026. Settings shows only these two numbers per model.
- Measured usage is about 17k input + 2.5k output tokens per conversation day. That's
  about **$0.06/day on Sonnet 5.5** and under $0.01/day on Luna, with thinking off.
- Code changes:
  - `spec_for/2` routes direct Sonnet → `anthropic:claude-sonnet-5-5` and direct Luna → `openai:<id>`.
  - OpenRouter slugs for both.
  - `get_api_key(:openai)` reads `OPENAI_API_KEY` (runtime.exs, `.env.example`, README).
  - Thinking placement for `:openai`.
  - Stats pricing tiers for both models.
- **Verify before coding:** the exact Luna API id and OpenRouter slugs (via
  `/v1/models`), whether Sonnet 5.5 accepts `thinking: disabled`, and which reasoning
  param Luna takes.
- **Delete:** Sonnet auto-discovery, the 404-retry, `Cache`.

## Deletions

- **Live views:**
  - `HomeLive`
  - `EntryLive.{New,Edit,Show}` (merged into one `JournalLive`)
  - `ConversationLive.{New,Continue,Show}` (merged into one `ConversationLive`)
  - `FocusTopicsLive`
- **Contexts and AI modules:** `FocusTopics`, `FocusSummarizer`, `PromptCache`, `Cache`,
  `TopicGenerator`, `PromptGenerator`.
- **Features:** versioning, forking, and "continue" branching; review `commentary` tips
  (the focus engine now covers "what to work on").
- **Settings fields** listed under Data model.
- **Docs and scripts:** the GLM-specific settings copy and docs. All four scripts in
  `scripts/` are replaced by the benchmark (phase 1).

## Phases (each ends with `mix precommit` green)

1. **Models and benchmark.** We pick the default model and whether thinking is on from
   measurements, not guesses, so this ships first. Add OpenAI as a provider
   (`OPENAI_API_KEY`), the model specs, and pricing. Then build the benchmark below, run it
   on Sonnet 5.5 and Luna with thinking off and on, and grade the output. Only then slim
   the Settings card to the winners.

   **Benchmark.** `mix run scripts/bench.exs <provider:model> [--thinking on|off]` runs
   every AI purpose the daily flow uses through the production functions and writes
   `tmp/bench/<model>-<thinking>.json`. An agent runs it and grades the file.
   - Per case it records the input, raw output, parsed result, parse status, latency,
     input/output/reasoning tokens, and cost. Per purpose it totals parse misses.
   - A day-cost line multiplies per-purpose averages by the daily call mix: 5
     corrections, 6 partner replies, 1 review, 1 flashcard batch, 1 starter, 1 focus.
   - Fixtures are inline, so no DB is needed: the German sentences from
     `check_corrections.exs`, each with its expected fix written next to it so there's
     something to grade against; a short French and Japanese set; one journal entry; and
     one 5-turn conversation. `SessionStarter` and `FocusWriter` join the bench when
     phase 3 builds them.

   What the audit found has to change first:
   - The scripts ignore their model arg, because Settings beats `:ai_model` in
     `resolve_model/2`. The bench sets the model per call.
   - Production hides parse misses: `proofread_message` falls back to the uncorrected
     text and flashcards to `[]`. Both return an error instead, which the UI shows with
     its one error state.
   - `anthropic_shape/2` throws away ReqLLM's `reasoning_tokens` and `total_cost`. Keep
     both.
   - ReqLLM strips `thinking` on Anthropic whenever a tool is forced, and every
     structured purpose forces one. So the bench reports "can't think with a forced tool"
     instead of faking an "on" run. If thinking turns out to matter, those calls switch to
     `tool_choice: auto`.
2. **Core domain.** Write the fresh migration and the `Activities` context, plus pure
   `Planner`, `Focus.choose`, and `Streak` modules with unit tests (picks are
   deterministic per date; covers freshness, cold start, bonus → freeze, and the streak
   walk). Then `Today.next_step/0` with DataCase tests for every step transition,
   including resume mid-day.
3. **AI.**
   - `SessionStarter`: continuity, angle, and focus.
   - `FocusWriter`.
   - Wrap-up additions: `summary` and `focus_result`.
   - Partner wrap-up on turn 5.
   - Flashcard ingest from `activities`.
   - Fix `feedback_lang/3`, which tells the model to write explanations "in de" because
     it passes the language code instead of the name.
   - Tests on prompt builders and normalizers (no network).
4. **Web.**
   - `TodayLive` (redirects and the done screen).
   - `ConversationLive`: chat, auto-end, and results on one page.
   - `JournalLive`: write, Finish at 5:00, results. The draft persists through autosave
     plus `AutoExpand`.
   - Cards step: Study in session mode, 20 flips, then back to `/`, with an inline "fix
     card" action.
   - Read-only History.
   - Nav: Today, History, Progress, Settings, About, in the hamburger menu on mobile.
   - LiveView tests for each step and for redirects.
5. **Wiring and polish.**
   - Reminders use `Today`'s day-passed status.
   - Celebration moves to the done screen.
   - Progress queries move to `activities`.
   - Designed loading states for opener and focus generation.
   - gettext extract and merge, with German filled in.
   - README and AGENTS.md updated.
   - Phone-width check in light and dark mode.

## Assumptions (correct any that are wrong)

1. "5 conversations" means 5 of *your* messages. The partner's 5th reply wraps up, then
   results load automatically. You can't keep chatting past that.
2. The journal Finish button appears 5:00 after the entry was started (wall clock, so it
   survives a refresh) and needs non-empty text. There's no word floor.
3. The OpenAI key is an env var like the others, not entered in the UI.
4. Thinking stays off everywhere, for latency and cost. Revisit for corrections only if
   quality disappoints.
5. The bonus activity reuses today's focus.
6. Prod reset: you delete `/app/data/daily_output.db` at deploy. Locally I back up the dev
   DB (timestamped copy, matching the existing ones) before `mix ecto.reset`.
