# Engagement & Retention Design

Daily Output is effective for practice but **hard to stick with** — easy to forget,
easy to avoid. This document is the plan to make it enticing without watering down
the practice.

## The two problems

1. **Forgot** — nothing pulls you back. There is no reminder loop today.
2. **Avoided** — the daily ask is big *and* rigid. The streak requires a completed
   timed entry **and** a full conversation, and a single miss resets the streak to **0**.
   When you only have five minutes you can't "win," and one slip erases everything — so
   the rational move becomes "why bother."

Fixing notifications alone just nags you about a goal that's easy to fail. We fix the
**ask** and add the **nudge**.

## What already exists

- Streak counter + daily challenge (1 entry + 1 conversation, both with feedback) — `FocusTopics.current_streak/0`, `FocusTopics.daily_challenge_status/0`
- 14-day activity history on the home screen
- Installable PWA: `priv/static/manifest.json`, `priv/static/sw.js` (network-first SW)
- **Missing:** scheduler/jobs, push, email, timezone handling (everything is `Date.utc_today/0`)

## Cross-cutting prerequisite: a clock that respects the user

Today/streak math uses **UTC**. A "remind me at 8pm" feature and a fair "did I practice
today" boundary both need the user's local time.

- Add a `timezone` setting (IANA name, e.g. `Europe/Berlin`), default from an env var.
- Introduce `DailyOutput.Clock` with `today/0`, `now/0`, `day_range/1` that apply the
  configured timezone and a **4am day boundary** (a late-night session counts as "today").
- Migrate `today_range`, `current_streak`, and home's date grouping onto `Clock`.

---

## Phase 1 — PWA push notifications / nag  ← start here

Goal: if the day's goal isn't met by a configurable time, the user gets a push on their
phone (works with the app closed), with loss-aversion copy.

**Data model**
- New table `push_subscriptions`: `endpoint`, `p256dh`, `auth`, timestamps. One row per device;
  a device is "on" iff it has a row here (no global enabled flag).
- New table `vapid_keys`: the auto-generated `public_key`/`private_key` (see Server).
- `settings`: `reminder_time :time` (default 20:00), `timezone :string`,
  `last_reminder_on :date` (dedupe).

**Server**
- Add a maintained web-push dependency (`web_push_elixir`, pure Elixir — no NIF, Docker-safe).
- VAPID keypair: `DailyOutput.Vapid` generates one on first boot and stores it in `vapid_keys`,
  so a bare `docker run` has working push with no setup. The DB is the only source — no env
  vars, no generator task. Public key is exposed to the client.
- `DailyOutput.Push` context: `subscribe/1`, `list_subscriptions/0`, `delete_by_endpoint/1`,
  `send_to_all/1`, `send_to_endpoint/2` (per-device test); prunes subscriptions that return
  404/410 (expired).
- `DailyOutput.Reminders` GenServer: ticks each minute; when local time ≥ `reminder_time`,
  the goal isn't met, at least one device is subscribed, and `last_reminder_on` ≠ today →
  send push to all devices, stamp date. Started in the application supervision tree.

**Client**
- Settings: per-device "Daily reminder" controls + time picker. Enabling requests
  `Notification` permission, `pushManager.subscribe({ applicationServerKey })`, and sends the
  subscription to the server; the panel reflects *this* device's state and a total-device count.
- `sw.js`: add `push` (show notification) and `notificationclick` (focus/open `/`) handlers.
- The `Reminders` JS hook manages permission + per-device subscription lifecycle.

**Copy:** lead with loss aversion — *"Your 12-day streak ends in 4 hours."* / *"One quick
entry keeps your streak alive."*

**iOS caveat:** Web Push needs the PWA installed to the home screen (iOS 16.4+) and
permission granted. Document this in the settings UI.

**Tests:** subscription CRUD + pruning; `Reminders` decision logic (send vs skip) driven by
injected time + status; `Clock` boundary math. (Encryption/transport is the library's job.)

---

## Phase 2 — Flexible goal + streak protection (the retention fix) — DONE

- **Tiered days:** `FocusTopics.day_status/1` → `:full` (both tasks), `:partial` (one), `:none`.
  A *partial* day keeps the streak alive; a *full* day counts toward earning freezes.
- **Streak freeze (functional model):** `streak_info/0` derives everything from history —
  no extra table, no nightly tick, no timing bugs. You earn one freeze per 5 full days
  (capped at 3); the streak walk bridges missed days using that budget, but only when a
  freeze actually connects to an earlier kept day (never spends into the void). An
  unfinished *today* never zeroes the streak — it just leaves it at risk. `freezes_available`
  = earned − spent-in-current-run, shown as ❄ on the home streak badge. (Simpler and more
  forgiving than the persisted-counter sketch this doc originally had.)
- **Grace window:** 4am boundary via `Clock` (built in Phase 1).
- **Tests:** `day_status` tiers; partial-keeps-streak; today-not-done doesn't zero; gap
  without budget ends streak; earned freeze bridges a gap; clean streak keeps freezes unspent.

## Phase 3 — Growth & progress stats (intrinsic motivation) — DONE

- `DailyOutput.Stats.overview/1`: one pass over completed entries + conversations →
  lifetime words/entries/conversations/active-days/focus-mastered, a weekly
  **corrections-per-100-words** trend, and a 7-day recap. Words and corrections are both
  derived uniformly from `feedback["annotated_text"]` (`[[id:orig||corr]]` markers).
- `/progress` LiveView (linked in the nav): brutalist stat tiles, a CSS bar chart of the
  error-rate trend ("lower is better ↓"), and a "This week" recap card. Empty-state when
  there's no completed work yet.
- **Tests:** `correction_count`/`word_count`/`error_rate` helpers, `overview` aggregation
  against seeded data, and the page's empty + populated states.
- Deferred (optional later): focus-pool "quest log" framing; showing the recap on home.

## Phase 4 — Micro-sessions & delight (cut friction + reward) — DONE

- **Quick start: cut.** The "Schreiben" path already drops you straight into a freestyle
  entry, so a dedicated one-tap button was redundant clutter — not real friction removed.
  The reminder notification deep-links to `/`; the existing `Write →` is the one tap from there.
- **Unified soft floor (micro/warm-up + softer timer collapsed into one model):** the writing
  timer is now a *gentle target*, not a lock. `Journal.floor_met?/1` (a low word floor,
  `Journal.floor_words/0`) unlocks **Done**; the countdown still ticks and turns into a
  cheery `✓ Target!` when reached (`.timer-met`), never punishing. A short session just works
  and counts as a *partial* day (one task keeps the streak — `day_status/1`). Conversations
  mirror this: `Conversations.warmup_exchanges/0` unlocks **Done** well below the
  `min_exchanges` target, which stays the suggested goal. No separate mode, toggle, or
  config — one interaction model.
- **Celebration:** `DailyOutputWeb.Celebration` decides what fires after a task completes
  (day-complete beats a streak milestone — `FocusTopics.streak_milestone?/1`); the completion
  redirect carries a `?celebrate=` token the show page turns into a `push_event`, and the
  `phx:celebrate` listener in `app.js` renders brutalist falling blocks + a stamped headline
  (CSS keyframes matching the loader, reduced-motion aware). Warmer copy throughout.
- **Tests:** floor pure-functions (`floor_met?`/`words_until_floor`); `streak_milestone?`;
  `Celebration` decision + payload; quick-start creates/resumes the right draft; the entry
  floor gates/ungates **Done** live; a warm-up conversation at the floor finishes and marks
  the day *partial*.

---

## Sequencing rationale

Phase 1 first (your call). Phase 2 should land close behind so the nag points at a goal you
can actually hit. Phase 3 is the long-term "this is working" hook. Phase 4 is friction +
delight throughout. The `Clock` prerequisite is shared by Phases 1 and 2, so it's built in Phase 1.

## Open decisions (flagged before coding Phase 1)

1. **Dependency:** OK to add `web_push_elixir` (pure Elixir)?
2. **Timezone source:** a single `timezone` setting in the UI (recommended) vs an env-only value?
3. **VAPID provisioning:** ~~generator mix task + `.env` keys~~ — resolved: keys are
   auto-generated and stored in the DB on first boot. No env vars, no mix task.
