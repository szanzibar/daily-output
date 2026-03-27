# Sprachjournal

A daily language learning journal with AI-powered proofreading and feedback. Write in your target language, get instant corrections and learning tips.

Built with Phoenix LiveView, SQLite, and the Anthropic API.

## Features

- **Timed daily journal** — write for a configurable number of minutes in your target language
- **AI writing prompts** — contextual prompts based on your configured topics
- **Instant proofreading** — inline corrections (redline style) with explanations
- **Learning tips** — commentary on grammar patterns, phrasing, and word choice
- **Entry history** — track your writing over time with a streak counter
- **PWA** — installable on your phone for quick access

## Setup

### Prerequisites

- Elixir 1.15+
- An [Anthropic API key](https://console.anthropic.com/)

### Development

```bash
# Install dependencies
mix setup

# Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# Start the server
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

### Docker

```bash
# Generate a secret key
mix phx.gen.secret

# Create .env file
echo "SECRET_KEY_BASE=<your-generated-secret>" > .env
echo "ANTHROPIC_API_KEY=sk-ant-..." >> .env

# Run
docker compose --env-file .env up --build
```

## Architecture

- **Phoenix LiveView** — all pages are LiveViews, no dead views
- **Ecto + SQLite** — simple, file-based database
- **Anthropix** — Elixir client for the Anthropic API
- **Tailwind + daisyUI** — styling with a custom brutalist theme

### Contexts

| Context | Purpose |
|---|---|
| `Sprachjournal.Journal` | Entries CRUD, history, streak |
| `Sprachjournal.Settings` | User preferences (timer, languages, topics) |
| `Sprachjournal.AI` | Prompt generation and proofreading via Anthropic |

## Configuration

All configuration is done through the settings page in the app. The only external config is `ANTHROPIC_API_KEY` as an environment variable.

## License

MIT
