# DailyOutput

**Write and speak in your target language every day, get instant level-appropriate corrections — then drill your own mistakes as flashcards.**

A self-hosted, single-user language-practice journal built with Phoenix LiveView and SQLite. AI runs through [ReqLLM](https://hex.pm/packages/req_llm) — **GLM 5.2 by default, or Claude Sonnet 4.6** — direct or via OpenRouter. Installable as a PWA. Brutalist UI, no external design system.

## Why

The only way to get better at a language is to produce output — writing and speaking — regularly. DailyOutput gives you a daily structure: a timed journal entry, an AI role-play conversation, detailed corrections, and a streak to keep you honest. Feedback is calibrated to your CEFR level, so you only see mistakes you should actually know at that level, and every correction can become a flashcard you review later.

## Features

- **Timed journaling** — AI-generated prompts at your level, a focus timer, and a distraction-free editor that never loses a draft.
- **AI conversations** — natural role-play with a partner in your target language.
- **Inline corrections** — a clean rewrite with word-level strikethrough/insert markers and a short note on each change; catches unnatural phrasing, not just outright errors.
- **Flashcards** — cards distilled from your own mistakes, drilled with SM-2 spaced repetition and progressive fill-in-the-blank.
- **Focus pool** — save grammar tips from feedback and pick one to practice before each session.
- **Streaks** — a daily challenge (one entry + one conversation) with tiered streaks and earned freezes so one missed day doesn't reset you.
- **Progress** — words written and corrections per 100 words over time, plus your daily AI spend.
- **Daily reminders** — opt-in push notifications, managed per device.
- **Choice of model** — GLM 5.2 (default) or Claude Sonnet 4.6, via each vendor's native API or OpenRouter.
- **Installable PWA** — add to your home screen; English/German UI that switches to your target language at B1+.

## Screenshots

| | |
|---|---|
| ![Conversation prompts](priv/static/images/screenshots/conversation-prompts.png) | ![Conversation](priv/static/images/screenshots/conversation.png) |
| ![Corrections](priv/static/images/screenshots/conversation-corrections.png) | ![About](priv/static/images/screenshots/about.png) |

## Quick start

Run the published image with Docker Compose:

```yaml
# compose.yaml
services:
  daily_output:
    image: ghcr.io/szanzibar/daily-output:latest
    ports:
      - "${PORT:-4000}:4000"
    environment:
      # The AI key for the model/provider you pick in Settings. Default is GLM 5.2:
      ZAI_API_KEY: "your-zai-key"
      # ...or use ANTHROPIC_API_KEY (Claude) / OPENROUTER_API_KEY instead.
      # Public hostname your reverse proxy serves (used for HTTPS origin checks):
      PHX_HOST: "example.com"
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```

```bash
docker compose up -d
```

That's it. On first boot the container generates its `SECRET_KEY_BASE`, creates the SQLite database, and runs migrations — everything persists in `./data`. Web Push keys are generated automatically too; there's nothing else to configure.

**Behind a reverse proxy (production):** DailyOutput serves plain HTTP on container port `4000` and expects HTTPS origin checks for `PHX_HOST`. Terminate TLS at your proxy and forward to the published `PORT`, which maps to container `:4000`.

## Configuration

The only thing DailyOutput needs is **one AI key**, matching the model + provider you choose in Settings:

| Model | Provider | Key |
|---|---|---|
| GLM 5.2 *(default)* | Native API | `ZAI_API_KEY` |
| Claude Sonnet 4.6 | Native API | `ANTHROPIC_API_KEY` |
| either | OpenRouter | `OPENROUTER_API_KEY` |

Everything else is set on the in-app **Settings** page:

| Setting | Description |
|---|---|
| AI model & provider | GLM 5.2 or Claude Sonnet 4.6; native API or OpenRouter |
| Timer & exchanges | Minutes per entry; minimum conversation turns to complete |
| Flashcards per day | Target number of cards that make a full flashcard day |
| Target / native language | The language you're learning and your first language |
| CEFR level | A1–C2 — calibrates feedback difficulty and the UI-language switch |
| Topics & prompt context | Themes and custom instructions for AI-generated prompts |
| Daily reminder | Per-device push notifications at a chosen time |
| UI language & appearance | Auto/English/German; light, dark, or follow OS |

## Languages

DailyOutput works with **any target language** for AI feedback. Two have tuned conventions:

- **German** — written as Swiss Standard German (`ss`, never `ß`).
- **Japanese** — written in rōmaji (Hepburn), never kana or kanji.

The **UI** is available in English (default) and German, and auto-switches to your target language once you reach B1+.

## Local development

Requires Elixir `~> 1.15` (with Erlang/OTP) and Node.js (for the JS test suite).

```bash
mix setup                # deps, DB, assets
cp .env.example .env      # add an AI key — ZAI_API_KEY by default
mix phx.server            # http://localhost:4000
```

Run the checks before pushing:

```bash
mix test        # colocated with source under lib/
mix precommit   # compile (warnings as errors), format, full test suite
```

### Architecture

- **Phoenix LiveView** — every page is a stateful LiveView; no REST API.
- **Ecto + SQLite** — a single file-based database, no Postgres.
- **ReqLLM** — one client across providers (z.ai, Anthropic, OpenRouter).
- **Tailwind v4** — a custom brutalist theme; JS is limited to DOM measurement and textarea auto-expand.
- **Gettext** — English source strings, German translations.

| Context | Purpose |
|---|---|
| `Journal` / `Conversations` | Entries and role-play chats, with versioning |
| `AI` | Prompt generation, conversation, proofreading, flashcard/focus summaries |
| `Flashcards` | Spaced-repetition cards built from corrections |
| `FocusTopics` | Focus pool, daily challenge, streaks and freezes |
| `Stats` | Progress aggregation (words, corrections, spend) |
| `Settings` | Single-row user configuration |
| `Push` / `Reminders` | Web Push subscriptions and the daily nudge |
| `Clock` | Timezone + 4am logical-day boundary — the source of truth for day math |

## Contributing

Contributions welcome. Areas that could use help:

- Additional UI translations (add a locale under `priv/gettext/`)
- Tuned conventions for more target languages (`DailyOutput.AI.LanguageProfile`)
- Accessibility and mobile-UX refinements

## License

MIT — see [LICENSE](LICENSE).
