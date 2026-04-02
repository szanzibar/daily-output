# DailyOutput

A daily language learning app with AI-powered proofreading, conversation practice, and gamified daily challenges. Write and speak in your target language, get instant inline corrections and learning tips.

Built with Phoenix LiveView, SQLite, and the Anthropic API. Swiss brutalist UI design.

## Features

### Journal Entries
- Timed daily journal with AI-generated writing prompts
- Configurable timer (default 5 minutes)
- Distraction-free monospace editor

### Conversations
- Role-play conversations with an AI partner
- AI responds naturally in Swiss Standard German
- Configurable minimum exchanges before completion

### AI Feedback
- Inline corrections (college professor style) — strikethrough + green corrections with annotations positioned below
- JS-powered dynamic line wrapping and annotation placement
- Commentary section for grammar patterns and suggestions
- Feedback language switches to German at B2+ level

### Practice Mode
- Retype corrected text character-by-character
- Real-time visual feedback (correct = black, wrong = red highlight)
- Conversation practice jumps between user messages with AI context

### Daily Challenge
- Two tasks: Eintrag (journal) + Gespräch (conversation)
- Each task has two stages: written (½) and practiced (✓)
- Streak counter tracks consecutive fully-completed days
- Activity history grouped by date with completion indicators

### Other
- Entry/conversation versioning (multiple per day, soft delete)
- Auto-discovers latest Claude Sonnet model from API
- PWA installable on phone
- Docker deployment with auto-migration on start

## Setup

### Prerequisites

- Elixir 1.15+
- Node.js (for JS tests)
- An [Anthropic API key](https://console.anthropic.com/)

### Development

```bash
# Install dependencies
mix setup

# Create .env with your API key
cp .env.example .env
# Edit .env with your ANTHROPIC_API_KEY

# Start the server
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

### Docker

```bash
# Create .env
cp .env.example .env
# Edit with your ANTHROPIC_API_KEY and SECRET_KEY_BASE (run: mix phx.gen.secret)

# Deploy (or use deploy.sh)
./deploy.sh
```

### Testing

```bash
# Runs 72 Elixir tests + 29 JS tests
mix test
```

Tests are colocated with source files (in `lib/`), not in `test/`.

## Architecture

- **Phoenix LiveView** — all pages are LiveViews
- **Ecto + SQLite** — file-based database, no Postgres needed
- **Anthropix** — Elixir client for the Anthropic API
- **Tailwind 4 + daisyUI** — custom brutalist theme
- **Minimal JS** — only for DOM measurement (annotated text rendering) and textarea hooks

### Contexts

| Context | Purpose |
|---|---|
| `DailyOutput.Journal` | Entries CRUD, versioning, word count |
| `DailyOutput.Conversations` | Conversations + messages, versioning |
| `DailyOutput.Settings` | User preferences (timer, languages, topics, level) |
| `DailyOutput.AI` | Prompt/topic generation, conversation partner, proofreading |
| `DailyOutput.Practice` | Text extraction, char comparison, daily challenge, streak |
| `DailyOutput.Cache` | Key-value cache for API model discovery |

### Color System

| Color | Meaning |
|---|---|
| Yellow | Entry/Eintrag |
| Pink | Gespräch/Conversation |
| Blue | Üben/Practice, send actions |
| Orange | Settings, half-complete status |
| Green | Success/complete status |
| Purple | Secondary actions (+ Neu) |
| Cyan | Versions, save/draft |
| Dark | Delete, cancel |
| Red | Errors, corrections |

## Configuration

All configuration is done through the settings page:
- Timer duration, minimum conversation exchanges
- Target/native language, CEFR level (A1-C2)
- Topics for AI prompts
- Custom prompt context
- Practice mode toggle

The only external config is `ANTHROPIC_API_KEY` in `.env`.

Swiss Standard German is hardcoded in all AI prompts (no ß, Swiss terms).

## License

MIT
