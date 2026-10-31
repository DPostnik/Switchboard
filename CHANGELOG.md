# Changelog

User-visible changes to Switchboard, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): MAJOR for breaking changes to stored data, the Fringe or mobile protocols or the plugin and skill contracts; MINOR for new behavior; PATCH for fixes. The version of the working tree is in `VERSION`; `zsh scripts/release.sh X.Y.Z` cuts a release. Development notes and validation records stay in the local `docs/` directory.

## [Unreleased]

## [1.0.0] - 2026-10-31

First numbered release. Switchboard has been its author's daily client for Codex and Claude Code since September 2026; this version records the state after 263 commits. Earlier changes are in the git log only.

### Added

- Projects and chats: per-project chat lists, drafts, queued follow-ups, unread replies, quotes, file preview with drop and links, chat references and IDs, interface zoom, Russian and English interface.
- Agents: Codex App Server and the Claude Code CLI in app-owned homes, with agent, model, effort and Claude advisor chosen per chat; live sub-agents and background tasks; approval requests; account limits and context usage where the engines report them.
- Archive: agent-written summaries, local full-text search and "Find with agent"; tool outputs are capped while a chat is active and reduced to headline and metadata once it is archived.
- Scheduled jobs owned by the app for both engines, run chats and run history, schedule control and imports from chats.
- Agent browser: a Chrome for Testing per chat with page trees, cards, screenshots, uploads, and session import from the user's Chrome (cookies, Local Storage, IndexedDB).
- Mobile companion for iPhone through the user's own Supabase project, with infrequent publishing while the phone is not in use.
- Integrations: Fringe link, the app's own notch island, Telegram bridge, keep-awake, main window on the built-in display, agent-requested restart that waits for idle chats.
- Plugins and skills: the experimental Headroom provider plugin, the chat directory runtime, and the archive-summary, chat-search, history-patterns, routine-optimizer and schedule-control skills.

### Changed

- Repository layout for the release: design documents moved to `design/`, performance probes to `scripts/perf/`; the September browser research scripts and the workflow prototype were removed; the skill checks run with the test suite.

[Unreleased]: https://github.com/DPostnik/Switchboard/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DPostnik/Switchboard/releases/tag/v1.0.0
