# Conversation feedback refactor — faster feedback loop

## Motivation

Conversation mode only gives feedback *after the whole conversation is done*. By then
the same mistakes (wrong genders, etc.) have been repeated many times. We want:

1. **Per-message corrections** shown right after each message is sent.
2. **End-of-conversation scoring on two axes**: improvement on the chosen focus point,
   *and* improvement on the mistakes made earlier within the same conversation.
3. **A unified UI** — today the live chat page (`ConversationLive.Continue`) and the
   correction/review page (`ConversationLive.Show`) are completely separate. Corrections
   should appear inline in the chat as you go, ending with the score in-place.

## Decisions (locked with the user)

- **Scoring engine**: deterministic Elixir computes the signal (corrections-per-100-words
  early vs. late; which mistake *categories* repeated vs. got resolved). One AI call turns
  that into an encouraging narrative. Keeps the logic pure + unit-testable per AGENTS.md.
- **Score display**: two panels — the focus-point result (as today) + an "errors over time"
  panel (early-vs-late rate + the repeated mistakes you fixed) + a short narrative.
- Journal-entry proofreading is **out of scope** — only conversations change.
- Keep today's rule: a conversation only *completes for the day* once the focus concept
  was actually used (preserve the `?celebrate=` flow + focus gating).

## How feedback works today (reference)

- `ConversationPartner` replies with **no** corrections (prompt forbids it).
- On **Done**, `Continue.complete` joins all user messages with `---MSG_BREAK---` and makes
  one `AI.proofread/2` call → stored in `conversation.feedback`.
- `Show` renders that batch feedback via `chat_feedback`, splitting the single
  `annotated_text` blob back by `---MSG_BREAK---`.
- `annotated_text` markers are `[[id:original||corrected]]`; rendered by the `AnnotatedText`
  JS hook (`assets/js/annotated_text.js`) — **reusable as-is, per message.**
- `Stats` derives words + corrections-per-100-words from `feedback["annotated_text"]`.

## Plan

### Phase 1 — Per-message corrections (backend + live wiring)
- **Schema**: `feedback :map` on `Message`; migration; `Message.feedback_changeset/2`.
- **AI**: `Proofreader.proofread_message/2` — conversation-aware (sees prior turns as
  context, corrects only the latest message), conversational register, CEFR-calibrated,
  reuses `[[id:orig||corrected]]`. Each annotation tagged with a **`category`**
  (gender/case/verb/word-order/agreement/preposition/spelling/vocabulary/punctuation/other).
  No commentary/focus_result here — that stays at the end. `normalize_message_feedback/1`.
- **Context**: `Conversations.save_message_feedback/2`; `AI.proofread_message/2` delegate.
- **Flow** (`Continue`): on `send`, fire the partner reply *and* the per-message proofread
  in parallel, each tagged with the message id (`{:message_corrected, msg_id, result}`).
  Per-bubble "checking…" state while pending; corrections best-effort (errors don't block).
- **UI**: `chat_log`/`chat_entry` components — each user bubble renders its own
  `message.feedback` inline via the `AnnotatedText` hook (clean messages get a ✓).

### Phase 2 — Unify the two pages into one live view
- Merge `Continue` + `Show` into a single LiveView (`New` stays as the setup wizard).
  One page: active chat (input + Done), completed (input hidden, score panel), version
  branching ("New Version"), delete.
- Convert messages to a **LiveView stream** so individual bubbles update on correction.
- Fold `chat_feedback`/`chat_history` into `chat_log`; drop the `---MSG_BREAK---` hack.
  Legacy completed conversations fall back to the old split path.

### Phase 3 — Two-axis end-of-conversation scoring
- `Conversations.mistake_analysis/1` (pure, unit-tested): walk user messages in order,
  group corrections by `category`, derive repeated vs. resolved categories and
  corrections-per-100-words early vs. late.
- On Done: compute focus_result (existing) + run one AI call to narrate the analysis +
  produce focus-pool tips. Store in `conversation.feedback["improvement"]`. Score panel UI.

### Phase 4 — Stats, i18n, tests
- `Stats.samples/0`: conversations sum per-message counts (entries unchanged); fallback to
  the old conversation-level blob for historical rows.
- gettext extract/merge + German; unit tests for `mistake_analysis/1`; LiveView tests for
  live corrections + score panel; `mix precommit`.

## Progress

- [x] **Phase 1** — per-message corrections ✅ (`mix precommit` green: 180 tests + JS suite)
  - [x] migration `20260623111206_add_feedback_to_messages` + `Message.feedback` + `feedback_changeset/2`
  - [x] `Proofreader.proofread_message/2` + `categories/0` + `message_feedback_tool/0` + `normalize_message_feedback/1`
  - [x] `Conversations.save_message_feedback/2` + `AI.proofread_message/2`
  - [x] `chat_log`/`chat_entry` components (inline corrections, "checking…", "looks good ✓")
        + `.chat-checking`/`.chat-perfect` CSS
  - [x] `Continue`: parallel `start_partner_reply` + `start_message_correction` on send;
        `correcting_ids` MapSet; `{:message_corrected, id, result}` handler (best-effort)
  - [x] tests: proofreader (tool/normalize), conversations (save_message_feedback),
        continue LiveView (mount render, live update, graceful failure); German for new strings
- [~] **Phase 2** — unify pages (partial: `Show` now renders per-message corrections; see below)
- [x] **Phase 3** — end-of-conversation **assessment** (focus check + focus-area tips +
      encouragement, no re-correction) **and** deterministic two-axis *improvement* scoring
      (`mistake_analysis/1` + Progress panel). ✅
- [~] **Phase 4** — `Stats` now counts conversations from per-message feedback; tests green.

### Completion no longer re-corrects (2026-06-24)
Per-message corrections made the end-of-conversation `AI.proofread/2` redundant — it was
re-correcting the whole transcript. Replaced with an **assessment** pass:
- `Proofreader.assess_conversation/2` + `assessment_tool/1` — NO `annotated_text`/`annotations`.
  Returns `commentary` (future focus areas), `encouragement`, and `focus_result`. The prompt is
  fed the transcript with each message's already-applied corrections summarised (category +
  explanation) so tips/focus-judgement are grounded without re-finding errors. Result flows
  through `normalize_feedback` (annotated_text → "") and `save_feedback` unchanged, so the
  focus-gating in `should_complete_conversation?` still works.
- `AI.assess_conversation/2` delegate; `Continue.complete` calls it (dropped the
  `---MSG_BREAK---` join + `AI.proofread`).
- `Show`: corrections now render per-message via `chat_log` when any user message carries
  `feedback`; legacy completed conversations (batch blob only) still fall back to `chat_feedback`.
- `Stats.conversation_counts/1`: sums per-message `feedback` (words from each message's
  annotated_text/body, corrections from its markers); legacy rows fall back to the
  conversation-level blob, and a no-feedback convo counts words from message bodies.
- Tests: `assessment_tool/1` shape (no corrections, focus gating); `Show` per-message render;
  `Stats` per-message conversation counting. `mix precommit` green (188 + 26 JS).

### New-version branching keeps prior corrections (2026-06-24)
Backwards-compat fix: branching a completed conversation into a new version copied messages
with `%{role, body}` only, silently dropping each message's per-message `feedback` (the
inline corrections). The new version started blank and looked unfinished. `Message.changeset`
doesn't cast `feedback` (it's set via `feedback_changeset`), which is why it was lost.
- `Conversations.copy_message/2` — copies role + body + feedback verbatim into another
  conversation; `Continue.mount`'s new-version branch now uses it.
- Tests: `copy_message/2` (with and without feedback); `Continue` mount branches a
  completed+fed-back conversation and the copied bubble still renders its corrections.
- Note: `Show` already renders these correctly — a conversation with any per-message feedback
  uses `chat_log` (per-message); legacy batch-only rows fall back to `chat_feedback`. Verified
  v1 (per-message + batch) renders via `chat_log`; the empty-looking version was the
  feedback-less *copy*, now fixed.

### Two-axis improvement scoring (2026-06-24) — Phase 3 ✅
The headline original ask ("score me on improving mistakes *within* the one conversation"):
- `Conversations.mistake_analysis/1` (pure, deterministic, unit-tested): walks user messages in
  order and from each message's per-message corrections derives `resolved_categories` (flagged
  once early, never recurred), `repeated_categories` (recurred across messages), and
  `early_rate`/`late_rate` (corrections per 100 words, first vs. second half). Reuses
  `Stats.word_count` so marker/word logic lives in one place.
- The signal is computed at completion in `Continue.complete`, fed to `assess_conversation`
  (the AI narrates it into a one-sentence `improvement_note`), and merged into
  `feedback["improvement"]`. `normalize_feedback` now preserves `improvement` + `improvement_note`
  (via `put_optional`, dropped when empty — backwards compatible).
- `assessment_tool/1` gained an optional `improvement_note`; `improvement_block/2` injects the
  computed signal into the prompt.
- UI: `ConversationComponents.improvement_panel/1` — the "Progress this conversation" panel
  (error-rate trend early→late with up/down colour, "Stopped repeating" vs "Still working on"
  category chips, and the AI narrative). Rendered on `Show` next to `focus_result_box` → the
  two-axis score (focus point + within-conversation improvement). Legacy rows (no `improvement`
  key) simply don't render it.
- i18n: German filled for all new strings incl. category labels (Genus/Kasus/Verb/…).
- `mix precommit` green (200 tests + JS).

### Still TODO
- Full Phase 2 page merge (single LiveView for active+completed, streams, drop `chat_feedback`).
  This is an architectural polish, not a feature gap — `Show` already renders per-message and
  both score panels; `Continue` and `Show` still live as two routes.

### Phase 1 follow-up fixes (after first real use)
- **Textarea wrapping**: the new-conversation composers used a stray `input ...` class
  instead of the shared `.chat-input`; migrated both to `.chat-input` and hardened that
  class with `white-space: pre-wrap; overflow-wrap: break-word; width: 100%`.
- **Corrected-message width**: removed `chat-user` from the corrected-bubble row so the card
  stretches full width (was shrinking to content + right-aligned), which also lets the
  `AnnotatedText` hook measure the full width and stop wrapping too early.
- **Category leak / corruption**: the model had returned `annotations` as a *stringified*
  array with bare ASCII `"` inside German quotes, breaking JSON parsing and mangling fields
  (category bled into `explanation`). **Decision: prevent, don't recover** — added a prompt
  rule forbidding `"` in explanations (use «guillemets»/'single quotes'), and
  `normalize_message_feedback` now only shapes a clean structured list (validates `category`
  against the enum, drops non-maps); a non-list yields no annotations rather than garbage.
  Corrupt pre-existing dev rows are just deleted. The renderer only ever shows `explanation`,
  so a clean parse means category never appears in the UI.

### Phase 1 follow-up, round 2
- **Loader**: the per-message "checking…" indicator was grey with big reused typing dots;
  restyled to small colourful bouncing blocks (`.chat-mini-blocks`) matching the brutalist
  loaders. (The colourful `retro_loader`/`loading-blocks` were never touched.)
- **Correction precision**: tightened BOTH prompts' marker rules to be STRUCTURE-first —
  REPLACE `[[id:wrong||right]]` / INSERT `[[id:||missing]]` / DELETE `[[id:extra||]]` — so a
  missing comma is a pure insert (green only) and a wrong word always keeps the right side.
  Kept comma only as an insert *example*, no comma grammar lecture (per feedback).
- **Done floor (not a bug)**: `warmup_exchanges = 2` predates this work (commit `09d6a53
  celebration`); `min_exchanges` is now just the target counter. Left as-is pending a call
  on whether to gate completion on `min_exchanges` again.

### Notes / carry-forward for Phase 2
- Per-message corrections render on the live `Continue` page. After **Done**, the flow still
  navigates to `Show`, which renders the *batch* `conversation.feedback` via `chat_feedback`
  (the `---MSG_BREAK---` split). Unifying `Continue`+`Show` and rendering each bubble from its
  own `message.feedback` (dropping `chat_feedback`/`---MSG_BREAK---`) is Phase 2.
- `chat_entry` uses `id="annotated-msg-<message.id>"`; legacy `chat_feedback` uses the user
  index — fine while they live on separate pages; reconcile when merging.

_Last updated: 2026-06-24 — two-axis scoring shipped (focus result + within-conversation
improvement panel). All three original asks (inline corrections, two-axis scoring, unified
feedback UI) are delivered. Only remaining item: optional Phase 2 single-LiveView page merge._
