# TODO

## Done

- [x] Phoenix project scaffold with SQLite + Anthropix
- [x] Brutalist/Swiss design CSS theme with bold color system
- [x] Settings context + LiveView (timer, languages, topics, level, prompt context)
- [x] Journal context + entries schema with soft delete + versioning
- [x] New entry LiveView with AI prompts, timer, distraction-free editor
- [x] AI prompt generation (Anthropix, auto-discovers latest Sonnet model)
- [x] AI proofreading with annotated_text format ([[id:orig||corrected]])
- [x] Inline corrections — JS-powered dynamic line wrapping + annotation positioning
- [x] Entry show page with version navigation
- [x] Entry edit + resubmit (creates new version)
- [x] Conversation/role-play mode with AI partner
- [x] Conversation topic opener generator
- [x] Conversation feedback with interleaved chat + corrections
- [x] Conversation continue/branching (new version if has feedback)
- [x] Practice mode — retype corrected text with real-time char comparison
- [x] Conversation practice — jumps between user messages with AI context
- [x] Daily challenge system (entry + conversation, half/complete states)
- [x] Streak counter (consecutive fully-completed days)
- [x] Activity history grouped by date with completion indicators
- [x] Configurable CEFR level — feedback language switches at B2+
- [x] Swiss Standard German hardcoded (no ß, Swiss terms)
- [x] Dotenvy for .env loading
- [x] Model auto-discovery via Anthropic API (cached 24h)
- [x] Dockerfile + docker-compose.yml + deploy.sh
- [x] Auto-migration on server start
- [x] PWA manifest + service worker (network-first, SW disabled in dev)
- [x] SVG logo + PNG icons
- [x] Comprehensive test suite (72 Elixir + 29 JS, colocated with source)
- [x] JS business logic extracted into testable module (annotated_text.js)

## Ideas for Later

- [ ] Speech-to-text integration (Whisper via Docker)
- [ ] Streaming AI responses
- [ ] Spaced repetition for corrections (resurface past mistakes)
- [ ] Vocabulary tracking across entries
- [ ] Progress analytics (words per day, error rate trends)
- [ ] Export entries (markdown, PDF)
- [ ] Full history page with search/filter
- [ ] Tighten streak to require consecutive calendar days (not just any activity)
- [ ] Multiple target languages support
- [ ] Gamification: XP points, levels, badges
