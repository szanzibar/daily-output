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
- New table `push_subscriptions`: `endpoint`, `p256dh`, `auth`, timestamps. One row per device.
- `settings`: `reminders_enabled :boolean`, `reminder_time :time` (default 20:00),
  `timezone :string`, `last_reminder_on :date` (dedupe).

**Server**
- Add a maintained web-push dependency (`web_push_elixir`, pure Elixir — no NIF, Docker-safe).
- VAPID keypair: a `mix daily_output.gen_vapid` task prints a keypair; keys read from env
  (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`). Public key also exposed to the client.
- `DailyOutput.Push` context: `subscribe/1`, `list_subscriptions/0`, `delete/1`,
  `send_to_all/1`; prunes subscriptions that return 404/410 (expired).
- `DailyOutput.Reminders` GenServer: ticks each minute; when local time ≥ `reminder_time`,
  the goal isn't met, reminders are on, and `last_reminder_on` ≠ today → send push, stamp date.
  Started in the application supervision tree.

**Client**
- Settings: "Daily reminder" toggle + time picker. Toggle requests `Notification` permission,
  `pushManager.subscribe({ applicationServerKey })`, POSTs the subscription to the server.
- `sw.js`: add `push` (show notification) and `notificationclick` (focus/open `/`) handlers.
- A small JS hook `PushToggle` to manage permission + subscription lifecycle.

**Copy:** lead with loss aversion — *"Your 12-day streak ends in 4 hours."* / *"One quick
entry keeps your streak alive."*

**iOS caveat:** Web Push needs the PWA installed to the home screen (iOS 16.4+) and
permission granted. Document this in the settings UI.

**Tests:** subscription CRUD + pruning; `Reminders` decision logic (send vs skip) driven by
injected time + status; `Clock` boundary math. (Encryption/transport is the library's job.)

---

## Phase 2 — Flexible goal + streak protection (the retention fix)

- **Tiered days:** `:full` (both tasks) vs `:partial` (one) vs `:none`. A *partial* day keeps
  the streak alive; a *full* day earns a gold star and progress toward a freeze.
- **Streak freeze:** `streak_freezes` (earn one per N full days, cap a few). When a day ends
  incomplete and a freeze is available, the nightly tick records a `frozen_day` and decrements.
  `current_streak/0` treats frozen days as bridged.
- **Grace window:** 4am boundary via `Clock` (shared with Phase 1).
- Home + streak badge reflect partial/full/frozen states.
- **Tests:** streak math across full/partial/frozen/missed sequences; freeze earn/consume.

## Phase 3 — Growth & progress stats (intrinsic motivation)

The app generates feedback daily but never aggregates it. Show improvement.

- `DailyOutput.Stats`: words written, entries/conversations, **corrections-per-100-words trend**
  (from feedback annotations), focus points mastered over time.
- `/progress` LiveView: brutalist CSS/SVG bar+line charts (no chart dependency).
- **Weekly recap card** ("5 days · 1,400 words · 2 focus points mastered · fewer dative slips"),
  shown on home Monday-ish and screenshot-able.
- Reframe the focus pool as a quest log: "master 3 this week."
- **Tests:** aggregation against seeded entries/conversations; recap windowing.

## Phase 4 — Quick-start, micro-sessions & delight (cut friction + reward)

- **Quick start:** one tap → freestyle entry created → straight into the editor. Notifications
  deep-link here.
- **Micro / warm-up mode:** shorter timer + fewer exchanges; counts as a *partial* day.
- **Softer timer:** "Done" allowed once a low floor is met; celebrate beating the target.
- **Celebration:** brutalist confetti-blocks on day-complete and streak milestones; more
  personality in copy.
- **Tests:** quick-start creates the right draft; micro-session marks partial.

---

## Sequencing rationale

Phase 1 first (your call). Phase 2 should land close behind so the nag points at a goal you
can actually hit. Phase 3 is the long-term "this is working" hook. Phase 4 is friction +
delight throughout. The `Clock` prerequisite is shared by Phases 1 and 2, so it's built in Phase 1.

## Open decisions (flagged before coding Phase 1)

1. **Dependency:** OK to add `web_push_elixir` (pure Elixir)?
2. **Timezone source:** a single `timezone` setting in the UI (recommended) vs an env-only value?
3. **VAPID provisioning:** I'll add a generator mix task + `.env` keys — confirm that fits your deploy.
