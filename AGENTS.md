# Daily Output

A self-hosted, single-user language-practice app (Phoenix LiveView, SQLite, installable
PWA). Each day you write or talk in your target language, the AI corrects you, and your
mistakes come back as flashcards. It works for any language pair; the maintainer learns
German. The UI is English and German.

It runs a guided daily flow where the app decides everything. `docs/guided-daily-flow.md`
is the record of the flow's decisions and why we made them.

These standards override generic habits. When two of them pull against each other, pick
whatever leaves the reader with less to hold in their head.

## Commands

- `mix precommit` before you're done. It compiles with warnings as errors, formats, and
  runs the Elixir and JS suites. Fix everything it reports.
- `mix test path/to/file_test.exs` runs one file. Tests sit next to the code under `lib/`.
- `mix ecto.gen.migration name_with_underscores` creates a migration.
- `mix gettext.extract && mix gettext.merge priv/gettext` after changing UI strings.

## Architecture

We follow *A Philosophy of Software Design*.

- **Simplicity first.** What can we avoid doing? What can we do simpler? Added complexity
  needs a strong, clearly worded argument in the moduledoc or PR. Simple beats clever, and
  there's no abstraction for hypothetical futures. Priority: simplicity, readability, then
  performance.
- **Build strategically.** Fix the design, not the symptom. A fix goes in the shared
  function every caller routes through, not in the one caller the bug report names.
- **Deep modules, small interfaces.** One domain module with plain function names beats a
  pile of tiny single-verb modules. Hide the rules behind the interface. Names say what the
  function actually does.
- **Built to experiment.** We're still finding the flow that keeps practice daily. The web
  layer asks one module what to do next and never encodes the flow itself. Picking rules
  are pure functions that take their inputs, so swapping one is a local change.
- **Derive state from data** instead of adding tables, schedulers, or caches. Streak
  freezes come from walking the history, not a stored counter.
- **AI cost and latency matter, scale doesn't.** It's one user on SQLite, so load the rows
  and do it in Elixir if that's simpler. Every AI call costs tokens and makes the user
  wait, so a new one has to earn its place. Check `api_usages` before and after prompt
  changes.
- **Don't over-extract.** Following small single-use functions around a file costs more
  than it saves, so default to inline. Extract only when the code is reused, is a
  genuinely separate concern, or multi-clause matching is its natural form. Merge a
  function into its only consumer. No passthrough wrappers or `defdelegate` facades. A
  value used once stays inline.
- **Minimal error handling.** Let it crash for things that shouldn't happen: `=` matches
  and bang functions. AI calls fail in normal use, so each gets one designed error state in
  the UI, not per-reason plumbing. Losing what the user typed is never OK.
- **Don't hedge.** No branches for edge cases that won't realistically happen. A cheap,
  low-risk failure mode gets a one-line "known and accepted" comment, not a mechanism.
- **Tunables live where they're used**, as module attributes, not settings or config.
  Test-only values use `if(Mix.env() == :test, do: ..., else: ...)`. Config is for what a
  deployment actually changes, like API keys.
- **Comments are rare and say why**, in one or two plain lines. Don't restate the code,
  explain the obvious, or narrate the history that got us here. Older code is
  comment-heavy; code you write or rewrite follows this rule, but leave untouched code
  alone.
- **Logic has unit tests.** Keep logic pure so its tests don't need the DB, API, or
  browser (see `Planner`, `Streak`, `Reminders.due?/4`). Every behavior change adds or
  adjusts tests. No hidden helpers for a ~3 line setup; inline it in the test.

## Product

- **The app decides, not the user.** It picks the activity, topic, grammar focus, and
  flashcards. Manual management is cognitive load, and cognitive load kills motivation. No
  choice lists, regenerate buttons, or setup screens. The only escape hatches are for
  fixing AI mistakes, like a bad flashcard, and they should rarely be needed.
- **Polished and fun, never noisy.** Give clear feedback. Toasts auto-dismiss. Loading and
  empty states are designed, not afterthoughts.
- **Inputs never lose what you typed.** Every text field survives a refresh or leaving and
  coming back: use the `AutoExpand` hook with a stable `data-persist-key`.
- **One interaction model per concern.** Settings auto-save on change with a "Saved"
  toast. Never add save buttons.
- **Any language pair.** Never hardcode German. Language behavior comes from settings and
  `DailyOutput.AI.LanguageProfile`; name data generically (`target_text`, not `german`).

## Codebase rules

- **Day math goes through `DailyOutput.Clock`**: the user's timezone plus a 4am day
  boundary, so a late-night session still counts as today. Never use `Date.utc_today/0`.
- **Everything user-facing is translated.** Wrap strings in `gettext`, run extract and
  merge, then fill in the German `msgstr`s and clear `fuzzy` flags. Fuzzy or empty entries
  silently fall back to English.
- **All AI calls go through `DailyOutput.AI.chat/2` with a `purpose:`**, so cost tracking
  per feature works. Use `Req` for any other HTTP.
- **Push reminders are per device.** A device is on if it has a `push_subscriptions`
  row; there's no global flag. VAPID keys are generated into the DB on first boot, with no
  env vars.

### Web

- **Mobile-first.** Design for a narrow phone, then scale up with `sm:`/`lg:`. Rows wrap or
  stack, never overflow. The nav is a hamburger on mobile. Check every screen at phone
  width.
- **Light and dark mode.** `--color-ink`, `--color-paper`, and `base-content` flip between
  themes; the `block-*` colors don't, and set their own readable text color. Never put
  `text-ink` or `text-base-content` on a `block-*` background, because the text inverts in
  the other theme. Mute labels there with `opacity-*`. Check new UI in both themes.
- **Reuse the brutalist vocabulary** in `assets/css/app.css`: `brutal-btn`, `block-*`,
  `brutal-hr`, and the loaders. It's Tailwind v4 with no config file. Keep the
  `@import "tailwindcss" source(none)` + `@source` setup, and never use `@apply`.
- **The layout comes from the router's `live_session`**, so templates don't wrap
  themselves in `<Layouts.app>`. Use `<.icon name="hero-...">`, `<.input>`, and
  `<.rich_text>` for AI Markdown. Passing `class` to `<.input>` replaces all its default
  classes.
- **Only the `app.js` and `app.css` bundles are served.** No external `<script>` or
  `<link>`, and no inline `<script>`; vendor code is imported into the bundles. For
  template JS, use a colocated hook (`<script :type={Phoenix.LiveView.ColocatedHook}
  name=".Name">`). A `phx-hook` element needs a unique `id`, plus `phx-update="ignore"` if
  the hook owns its DOM.
- **Pure JS logic gets its own module** in `assets/js/` with a `node --test` file. Add new
  test files to the `test` alias in `mix.exs`, because it lists them by name.
- **LiveView tests assert on element IDs** with `has_element?/2`, not on raw HTML, so give
  key elements stable IDs.

## Writing

This applies to docs, moduledocs, comments, commit messages, and PR text.

- Trust the reader to have the context. Don't re-explain the domain or the alternatives.
- Make the point in as few words as possible. One short paragraph per decision:
  "<what> because <why>."
- Use simple, casual, everyday speech. Never academic, stuffy, or fluffy.
- Match the maintainer's voice, and reuse their own wording verbatim when it exists.
- Follow [Google's developer style guide](https://developers.google.com/style/highlights):
  active voice, present tense, short sentences.

The voice we want:

```
`Today` decides what you do next. Pages ask `next_step/0` and render the answer, so
reordering the flow is a one-line change here.

The pick is seeded by the date, so a refresh never changes today's activity.

Cards count as done when nothing is due, because a new user has no cards yet.
```

## Working style for agents

- **Keep your context clean.** Focus on planning and the big picture. Delegate building,
  checking, and searching to capable subagents, put these rules in every code-writing
  brief, and relay only the conclusions.
- **Verify external facts against the real source.** For model ids, prices, API response
  shapes, and library behavior, curl it, read `deps/` and `mix.lock`, or make a one-off
  call. Test stubs match what the real thing returns.
- **Push back** when a request conflicts with these principles, even the maintainer's
  own. A whole subsystem for one tiny value is a smell; say so before building it.
