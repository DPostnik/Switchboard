# Changelog

User-visible changes to Switchboard, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): MAJOR for breaking changes to stored data, the Fringe or mobile protocols or the plugin and skill contracts; MINOR for new behavior; PATCH for fixes. The version of the working tree is in `VERSION`; `zsh scripts/release.sh X.Y.Z` cuts a release. Development notes and validation records stay in the local `docs/` directory.

## [Unreleased]

### Added

- Protocol drift diagnostics: events, item types and fields from Codex or Claude Code that the adapter does not recognize are counted by name (never content) instead of disappearing silently; Settings → Accounts shows a one-line summary per agent and the first occurrence of each is written to the system log (category compatibility).
- Nightly agent CLI check: after the nightly tests, on AC power only, Switchboard compares the installed Codex and Claude Code with the verified versions and the latest published ones (npm, at most once a day), runs the no-inference live tests only for a newly installed unverified version, writes compat-status beside latest-status and notifies once per new problem or version.
- Code editor integration, as in T3 Code: files from answers, the preview, the new file tree and turn changes open in your editor at the right line (VS Code, Cursor, Zed, Windsurf, VSCodium, Xcode, Sublime Text and JetBrains IDEs are detected; choose one in Settings → General → Code editor), ⌘-click on a file in a chat opens it there, and the project menu offers "Open in VS Code" for the whole folder.
- Comments on turn changes: in the turn changes window, click a line number (Shift-click for a range), write what should change and "Add to message" puts the file, lines, the quoted diff and your comment into the chat's message for the agent; nothing is sent until you send it.
- Project file tree: the folder button in the chat toolbar (⇧⌘E) shows the chat folder's files in the side panel (git's view without ignored files, or a walk that skips hidden and build folders), with search, preview on click, "Add to message", "Open in" and drag into the composer.
- Codex web searches, image views and dynamic tool calls now appear among a chat's actions instead of being dropped.
- Structured actions: in an open actions card, Codex and Claude file reads, edits, searches, web fetches, sub-agents and MCP tools show a kind icon, a short title, a status badge (running, awaiting approval, denied, failed, done) and their files as links that open like other file links; an edit opens to its inline diff. Chats saved earlier keep their old rows.
- Agent plans: the plan Codex updates and the Claude to-do list (TodoWrite) appear in the conversation as a compact checklist with progress, updated in place as the turn goes on.
- Gemini CLI support via ACP, shown when the CLI is installed (app-owned install, Homebrew or PATH; otherwise Settings → Accounts says "Gemini CLI not installed" and nothing starts): sign in with Google from Settings → Accounts (the CLI runs the browser sign-in in a separate Switchboard profile, your ~/.gemini is unchanged), new chats on Gemini with its own default model from the session's model list, structured tool calls and plans in the transcript, and saved Gemini chats reopen and continue.
- ACP agent catalog: Settings → Accounts → Install Gemini CLI installs it into Switchboard's own folder from the ACP agent registry (npm with scripts disabled, never global; the registry version only when it is on the verified branch, otherwise the verified one) and reconnects; once installed it shows the version with Update to X (checked at most once a day when Settings opens) and Remove. A new ACP agent catalog section lists the registry's agents with a Refresh button and an Installed badge; installing other agents is coming later.
- Silent sub-agent check: every 3 minutes while sub-agents run, Switchboard looks for running ones that have reported nothing for 5 minutes (or their tool call's own time limit plus 3 minutes); they are marked "No response since …" in the sub-agent panel, and once the main agent is idle it gets one message per stall naming them, so it can check, stop and redo the work. Nothing is stopped or retried automatically.
- Chat files: a small tile at the chat's top right sums up its files ("2 changed +494 −4 · 3 mentioned") and grows into a floating panel, hidden again with its arrow; the panel lists, in collapsible sections with smooth animations, the files the chat's turns changed with +/− and every file it mentioned, read or edited. Changed files open a chat changes window with each file's diff turn by turn, mentioned files open in the preview and a button jumps to the message; Escape closes the chat and turn changes windows. A finished answer now ends with a card of its turn's changed files (created files with their type and size) instead of the "± N files" pill; a click opens the turn's changes at that file.

### Changed

- Chat files can be hidden completely: right-click the tile or the panel and choose "Don't Show Chat Files"; View → Show Chat Files brings them back in every chat. The panel now grows out of the tile's corner and shrinks back into it, and the tile's hover fades in one colour without a darker step.
- Agent answer format: the shared instructions now also ask agents to explain directly with examples from the task, without everyday analogies or metaphors.
- Agent CLI version policy: besides the exact verified builds, Codex and Claude Code versions on the same major.minor branch (for example Codex 0.160.x, Claude Code 2.1.x) now connect as unverified, with a warning beside the agent name in the sidebar and in Settings → Accounts and drift diagnostics shown there; other versions are still rejected.

### Fixed

- The PR badge in the composer (#123) no longer opens an empty popover with only its arrow and border: when the details cannot be measured beforehand, the popover sizes itself to them.
- The changed-files card under an answer keeps a gap above the next message; the next user bubble no longer touches it.
- A Claude chat whose sub-agents or other background tasks are still running no longer stops them when the next message uses a different model, reasoning level or advisor: the change is applied to the running Claude Code process; if Claude Code refuses it, the reply keeps the previous settings with a note and the new ones apply once the tasks are done.
- A Claude chat's queued messages can be resumed or sent now while Codex is disconnected; the queue buttons follow the chat's own agent.

## [1.1.0] - 2026-11-01

### Added

- Detailed activity: Claude thinking and Codex reasoning appear as a collapsed "Thinking · 12 s" row that expands to the text; shell commands show the command line, a check or "exit 1" badge and, when expanded, the last 200 lines of output with a copy button.
- Continue after limit reset: when a Codex or Claude turn stops on an exhausted usage limit, the chat shows the reset time and a "Continue after reset" button; once clicked, one "Continue where you left off." message is sent a minute after the reset (also after an app restart), unless you write yourself, the chat is busy or archived.
- Command palette on Cmd+K (Go menu): find chats across projects with their status, projects, pages and actions such as New chat, Needs you, Schedule, Archive, Usage and Settings, plus matches in message text; Cmd+1…9 open the nine most recent chats (shown as ⌘1…⌘9 in the palette), Cmd+Shift+[ and Cmd+Shift+] the previous and next chat in sidebar order including collapsed projects, in any keyboard layout, and Cmd+F searches the open conversation.
- Git branch at a glance: project rows and the composer show the current branch, a dot for uncommitted changes and ↑/↓ against the upstream; a chat whose last turn ran on another branch shows that branch in its row and offers "Switch back to X" above the composer.
- Git actions from the composer's branch chip: a "Git" popover with the branch state and Commit, Commit & push, Commit, push & create PR, Push, Pull (fast-forward only) and Create PR (with GitHub CLI); the commit sheet lets you exclude files and pre-fills a model-drafted message in the repository's style, the PR sheet drafts title and body (using the repository's PR template), picks the base branch and can mark a draft; pushing to the default branch asks for confirmation, actions wait while an agent works in the folder, and nothing is forced, rebased or retried.
- Pull request status: the composer and project rows show the branch's GitHub PR as «#123» coloured by state with a ✓/✗/• checks mark (read with your own `gh` sign-in); its popover offers "Open on GitHub" and a per-chat "Watch PR" that checks the open PR every 3 minutes and puts failing or passing checks, new reviews and comments, merge conflicts and merge/close into Needs you with a macOS notification, where "Send to agent" queues one message with the failing checks and a CI log excerpt (or the new comments), only when you click.
- Turn changes for projects in git repositories: each Codex or Claude turn is checkpointed at its start and end under hidden refs in the project's repository (index, HEAD and branches untouched), the answer shows "3 files changed · +12 −4", and a click opens a diff viewer with "Restore files to before this turn".
- Chats in their own git worktree: a new chat in a git project can work "In a new worktree" (created in ~/.switchboard/worktrees on a switchboard/… branch from the project's current branch when the first message is sent, renamed once after the chat's title) or in an existing worktree; the chat's agent, checkpoints, file links and branch chip use that folder, its sidebar row shows the worktree branch, its menu offers Show worktree in Finder and Copy path, and archiving or deleting it asks whether to remove the worktree (never with changes, never the branch).
- Edit and reorder queued messages: the pencil or a double-click edits a waiting message in place (Return saves, Shift+Return adds a line, Esc cancels), and Move up/Move down in its menu, VoiceOver actions or dragging a row change the sending order; a message already being sent cannot be changed, and an edit that arrives after its message went out is refused with a notice and its text goes into an empty composer.

### Changed

- The context ring beside the send button shows the percentage inside it.
- "Context and tokens" popover is easier to scan: the context share with a progress bar, aligned token counts grouped by thousands with spaces, the cached share in percent, the cache as "42 of 60 min", one update time and a shorter note.
- New light "sage" look: green-tinted surfaces instead of pure gray, a moss accent for actions and unread chats, amber for anything that needs you and clay for errors; fewer borders, a raised composer, tool calls as cards, softer code blocks, tables, quotes and callouts.
- Simpler sidebar: no New chat button at the top (use the pencil on a project or Cmd+N); one "Needs you" row gathers waiting chats, important items and notifications; Schedule, Archive, Usage and Settings sit in a bottom dock; chat and project menus are shorter and the same everywhere.
- Composer: one chip for agent, model and reasoning; a context ring with an amber dot when the Claude cache is expired replaces the context and cache text; following the answer is automatic; the role picked for a new chat no longer changes the project default.
- Project settings (formerly Permissions…): roles as cards, browser and sign-in, phone visibility and MCP servers in one sheet.
- Settings has five tabs: General, Notifications, Accounts, Browser and Advanced; browser changes apply by themselves once chats are idle.
- A context compaction shows as a full-width divider where it happened, "Context compacted: 120k → 30k · automatic" (or "· was 120k" when the size after is unknown), with the exact token counts in its tooltip, instead of a small badge; Claude Code compactions now appear too, and the sizes stay after reopening the chat.

### Fixed

- The Git and pull request popovers in the composer open at their full size on the side with more room and scroll instead of running past the screen edge.
- The Git chip opens a native menu at once instead of a popover: the branch with its sync state and changes as a header, then only the actions that apply; Push and Pull close the menu and run with a spinner in the chip, failures show git's output in an alert.

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

[Unreleased]: https://github.com/DPostnik/Switchboard/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/DPostnik/Switchboard/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/DPostnik/Switchboard/releases/tag/v1.0.0
