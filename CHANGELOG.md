# Changelog

User-visible changes to Switchboard, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): MAJOR for breaking changes to stored data, the Fringe or mobile protocols or the plugin and skill contracts; MINOR for new behavior; PATCH for fixes. The version of the working tree is in `VERSION`; `zsh scripts/release.sh X.Y.Z` cuts a release. Development notes and validation records stay in the local `docs/` directory.

## [Unreleased]

- Important run warnings now link directly to their scheduled task, and failed runs without chats explain where to inspect and retry them.

- Scheduled chat tasks now accept and deliver prompts enriched with precondition output instead of rejecting them as invalid.

- "Open in editor" in the change windows is disabled with an explanation when the file is no longer on disk, instead of doing nothing.

- Add Settings → Advanced → Folders for every project: folders added there apply like a project folder to Developer and operator chats and scheduled jobs in every project (Claude and Codex), never to Editor or Reader; the home folder and the app's data folder are refused.

- Claude chats no longer ask about sandboxed shell commands that contain a backslash; a command leaves the sandbox only with the CLI's own flag, and then only trusted project commands run unasked.

- Record why Claude's permission answers were given (for example a deny-list hit, a sandboxed command, or a request to leave the sandbox with the trust check's reason) in the permissions ledger, and count denied commands an agent retried in the same turn.

- Trusted project commands accept more everyday shapes without a prompt: reading a log the same command just wrote with `cat`, `grep`, `sed -n` or `wc -l`, `date`/`pwd`/`printf`, and a `cd` to the chat's own project (also `"$(pwd)"` or `"$(git rev-parse --show-toplevel)"`) before its scripts; a `cd` anywhere else and every other substitution still ask.

- Switch the provider of a new chat with a Claude/ChatGPT toggle beside the model chip, and show each chat's provider mark in the sidebar.

- Offer native session approval for Codex commands when supported by the engine.

- Load the history of a Codex chat that exceeds the message size limit in pages instead of showing an error.

- Allow Swift compiler macros to run inside the external command sandbox while keeping its OS boundary enforced.

- Run Codex chats with a shell inside an external OS boundary (the bundled nono helper): the project, its declared folders and preset caches work without command approvals, everything else is denied; signing, GitHub and git commands get the Keychain through the broker; app browser and diagnostics stay outside the boundary.

- Resume long Codex chats whose full history exceeds the message size limit.

- Skip an oversized Codex message with a chat notice instead of disconnecting the chat's process.

- Resume Codex chats in isolated processes when their role permissions change.

- Check bundled Python entry points and record command approval cwd coverage.

- Clear Claude warm ownership when background work wakes.

- Relocate project sessions and archive removed projects.

- Deliver session-scoped generated image previews to native and web chats.

- Preserve task ownership and restart boundaries in verification guidance.

- Distinguish main browser access from isolated agent sessions.

- Add bounded DOM inspection and accurate browser tool effect hints.

- Render character tables and provide unwrapped drawing windows.

- Show native project verification status.

- Count waiting chats once on the Needs you page and badge.

- Add an explicit verification queue with isolated task snapshots and contained executor locks.
- Recognize Codex browser tool approvals and offer chat-scoped consent using the correct protocol metadata.
- Count distinct approval prompts, clarify permission outcomes, and revoke failed browser chat grants.

- Share conservative project command matching across providers and explain unsupported Codex command exemptions without broadening file access.

- Select leased Chrome tabs for pointer and key input, focus text fields, and let observed JavaScript dialogs yield the command queue without replaying input.

- Let Codex chats control regular Google Chrome through a paired Switchboard extension, with per-chat tab ownership and the My Chrome permission.

- Simplify regular Chrome setup with connection status, one connect action and technical IDs hidden in details.

- Recreate expired Chrome tab groups before opening a new tab, without retrying browser mutations.

- Keep regular-Chrome control responsive to transport failures, preserve other tabs on detach, and prevent replay after a stalled operation.

- Isolate Codex Chrome-worker approval resets and disconnects, and preserve background children after their parent turn completes.

- Route Codex sessions through their owning provider or isolated Chrome process and preserve scoped browser access.

- Show Codex subagents with readable names, live steps, tool results, reports and individual stop controls.

- Support photo attachments, paste and drag and drop in the first message of a new web chat; prevent file navigation across all web screens.

- Prevent web photo drops from opening the image; accept file-item and image-URL drops and Windows copied photo files without an image MIME type.

- Web chats accept photo drag and drop and clipboard image paste (including Windows Ctrl+V), using the attachment picker’s previews and cloud delivery.

- Add photo attachments to the web composer using the mobile cloud delivery protocol.

- Coding chats gain project-scoped load, build-task and app diagnostics, plus a shared app verification workflow.

### Changed

- New Codex chats default to GPT-6.1 Sol. Existing installations adopt the app default once; saved chat and project model choices and later changes to the app default are preserved.

### Added

- Test stable Codex updates in isolation before switching the managed CLI; account settings explain when an unverified version prevents connection.
- Web client chats: the sidebar marks chats started in the web client with a Safari icon and the window subtitle says "started in the web client"; `switchboard-chat:web:<ID>` references now work with `inspect_chat` and `scripts/chat-lookup.sh`.
- Sidebar: "Remove project from list" is now "Hide project"; while projects are hidden, a button next to "Projects" lists them and shows any of them again with its chats, without adding the folder again.
- Chat servers: a "Servers" line above the composer lists the servers the chat's agent started (any process listening on a port, such as `npm run dev`), with the address that opens in the browser on click and a button that stops the server and its child processes; the right-click menu opens other ports, opens in Chrome or Safari and copies the address or the command. Codex servers are shown in the chats of their folder.
- File menus: HTML files get "Open in Google Chrome" and "Open in Safari" (for the browsers installed) in the chat files panel, project files, turn changes, the file preview and file links in the chat.
- Settings proposals: an agent in a sandboxed Claude chat can propose project settings changes (access sets, folders outside the project, commands outside the sandbox, the sandbox switch); the app opens a review with every change and applies it only when you press Apply.
- Command sandbox: `git worktree` is trusted in the GitHub set, so removing and pruning worktrees no longer asks.
- Command sandbox: trusted commands followed by `2>&1`, `| tail`, `| grep` with one pattern, output to /dev/null or a temporary folder, `cd` and `echo` no longer ask; in sandboxed chats the file tools read and write temporary folders without a prompt; read-only folders outside the project no longer block writes to writable folders inside them.
- Model defaults per project: Project settings → Model sets the model and reasoning a project's new chats start with; the model chip has "Make default in project" and "Make default in all projects". A model or reasoning picked in a new chat now applies to that chat only and no longer becomes the default of every project.
- Chats by ID: "Copy chat ID" now copies `switchboard-chat:<ID>`. When you send such a reference (or a chat's ID or its Claude or Codex session ID) in a Claude chat, that chat gets the `inspect_chat` tool for the chats you named: in one call it shows the chat, its agent session and transcript file, the latest turns, what the app saw (turn starts and ends, errors, background waits, stopped processes), refused requests and the latest transcript events. Chats with access to all chats can inspect any chat. `zsh scripts/chat-lookup.sh <ID>` shows the same in Terminal.
- Command sandbox for Claude chats with the Developer role: shell commands see only the project, its folders outside the project and the ticked shared access sets (GitHub, Node.js, Swift and Xcode, Python, browser engines, Vercel, Homebrew, agent CLIs, Downloads, Apple signing); the rest of the home folder is closed to them. A new project starts with the sets its files suggest. Commands from the sets and the project's own list (such as `gh`, `swift build`) run outside the sandbox without a prompt; any other command that leaves it asks you each time, and "allow for this turn" does not cover it. Read-only system queries (`ps`, `sysctl -n`) always run outside it. Project settings → Command sandbox.
- Project files panel: drawn in the app's colors (row selection and hover, search field like the chat files panel); folders open and close with a sliding animation and a turning arrow, and the arrow keys work as in Finder (Right opens a folder, Left closes it or goes to its parent).
- iPhone app: drop an image (such as the screenshot thumbnail) anywhere on the chat, or paste one from the clipboard with the Paste button that appears above it; Copy and Share show only under the end of the agent's reply, not under each progress note.
- Chat: image paths you paste into a message (screenshots, files from other apps) show as numbered chips with a small preview, in the sent message and in the message field; in the message field they are written as `[path]`, so they work right next to text, and you can drag them to another place in the text and open back into the path by deleting a bracket, with the images shown above the field (click to view, × to remove; removing a chip removes the image). Images open in a viewer over the window (zoom, arrows through the images, Esc to close). Pasting a screenshot from the clipboard saves it and inserts its path; Copy Image on a chip pastes back into the message field as the same file and into other apps as the picture.
- Chat job (Job button in the chat toolbar): set a "done when" criterion for the chat; the panel shows how long the job has been open, what the agent is doing now and the criterion, with Done and Cancel job (cancel also stops the running turn). The agent receives the criterion, and later that the job was closed, with your next message; the transcript does not show these notes.
- Web client looks like the Mac app: sidebar with the Mac, projects and chats, transcript with Markdown, code blocks with Copy and framed tables, approval and question cards, queue and a round send/stop button in the composer, light and dark themes.
- Web client (`Web/`, for Windows and any browser): sign in with the mobile access account, start chats on the Mac's agents and models, follow them with the full message text (up to 100,000 characters per message, the latest 500 messages), stop, queue, answer approvals and questions, and find earlier chats in the archive with the search agent and bring one back to the web. Only chats started from the web or brought back are shown; they leave the cloud 15 days after their last activity and stay on the Mac. Needs the cloud migrations `202611060001_remote_web.sql` and `202611060002_remote_web_cleanup_cron.sql` and an updated Mac.
- iPhone app: answer agent questions and forms from a card above the message field (options, your own answer, Decline; requests with secrets or links stay on the Mac), queue a message or interrupt and send while a chat works (its queue is shown), and choose the role and add-ons within the project default; the role chip shows the add-on icons. Needs the cloud migration `202611050001_remote_interactions.sql` and an updated Mac.
- Background tasks in Claude chats: the panel above the message field (beside sub-agents) lists the commands, dev servers, watchers and workflows the agent or its sub-agents left running in the background, with the command line, run time, the end of the output (refreshed every 2 s while it runs, colors removed) and a Stop button for each one; the agent keeps working. A sub-agent that waits for its own background commands shows as "Waiting for background tasks" and no longer disappears from the list when you send a new message.
- Your own skills in chats: Claude chats load `~/.claude/skills` and the app profile's skills, Codex chats `~/.codex/skills` (read-only, nothing is copied). The agent picks a skill by its description, a used skill shows as a "Skill: name" row in the chat, and typing `/` in the message field lists the engine's skills to insert (`/name` for Claude, `$name` for Codex). Claude Code's own bundled skills stay off.
- Role add-ons "Mail and connectors" and "My Chrome" (shown as envelope and globe icons on the lock chip): the lock chip and the project settings add Gmail and other connectors (reads silent, sends asked) or the user's Chrome to a chat's role, so a Developer chat no longer has to switch to Operator for them; scheduled jobs never get them.
- Binary files in a turn's changes card and in the chat files panel (PDF, images) open in the preview beside the chat instead of an empty diff; PDF documents are shown with PDFKit as scrollable pages fitted to the pane's width.
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

- iPhone app redesign: chats that need you and running chats are grouped above the projects with one Mac connection line, the pending approval and the agent's activity stay pinned above the message field, an unconfirmed send blocks only its own chat with clear next steps and is never resent automatically, and the language switch applies without a restart.
- Switching back to a recently viewed chat is instant: recent chats keep their rendered text (up to about 2 million characters in total).
- Agents in every project get a heavy-work rule with the app's instructions: each step that builds, tests, installs or runs a probe counts as heavy, at most 2 heavy steps run at a time on the Mac (checked against the load average), edits are compiled once per hypothesis instead of after every change, and orchestrators keep at most 2 heavy sub-agents running.
- The window stays responsive while chats stream: status lines, context usage and sub-agent updates no longer redraw the sidebar and the chat.
- A streaming answer shows its list of web sources once it finishes (or when a tool call follows it).
- Long chats take less memory, and a closed chat's text is released right away.
- Long chats open instantly: the last screens are shown first and older messages are added above while you read; find, Select All and jumps to old messages load the whole history at once.
- Streaming answers in long chats use less CPU: only the running request is regrouped on each update.
- Long code blocks and previewed source files scroll with less CPU.
- Searching the sidebar no longer stalls in large workspaces: results follow a short pause in typing, show at most 50 chats with Show all (N), and sidebar rows build their menus only when opened.
- Filtering large project file trees, the archive and the command palette no longer lags while typing.
- The chat search index takes less disk space and updates only new messages after a turn; it is rebuilt once after this update.
- Archive search answers short queries immediately (one or two characters list the newest matches first) and never shows results of an older query.
- Diff windows scroll smoothly; copy a diff line or its hunk from the line's context menu (Copy Line, Copy Hunk). Text can no longer be drag-selected inside a single diff line.
- Lower memory use with long chats, Claude and Gemini history, long Codex command output and large inline images (the image cache is capped and large images are decoded at display size).
- When macOS runs low on memory, Switchboard frees cached chat history (except the open chat) and decoded transcript images.
- Chat files can be hidden completely: right-click the tile or the panel and choose "Don't Show Chat Files"; View → Show Chat Files brings them back in every chat. The panel now grows out of the tile's corner and shrinks back into it, and the tile's hover fades in one colour without a darker step.
- Agent answer format: the shared instructions now also ask agents to explain directly with examples from the task, without everyday analogies or metaphors.
- Agent CLI version policy: besides the exact verified builds, Codex and Claude Code versions on the same major.minor branch (for example Codex 0.160.x, Claude Code 2.1.x) now connect as unverified, with a warning beside the agent name in the sidebar and in Settings → Accounts and drift diagnostics shown there; other versions are still rejected.

### Fixed

- Prefer Switchboard’s own verified Codex CLI when installed, so ChatGPT updates do not interrupt sign-in or model selection.
- Command sandbox: a trusted command that writes its log to a temporary file, shows its end with `tail`/`head` and exits with the command's status (`> "$TMPDIR/build.log" 2>&1; code=$?; tail -15 "$TMPDIR/build.log"; exit $code`) no longer asks
- Chat: a quick double click on the Project files button no longer leaves an empty column where the side panel was.
- Claude chats: when a background command ended before the agent's turn did, the agent's next turn on its result no longer runs unseen: its reply reaches the chat, its requests ask you instead of being refused as unattended, and the Claude process stays open for the following notifications.
- iPhone app: changing a chat's role from the phone is no longer rejected by the cloud database.
- Remote access: the connection to the server no longer stays down for good after a network drop during reconnect, so the iPhone sees the Mac again without turning remote access off and on.
- Claude chats: screenshots and PDFs in temporary folders and the user's own attachments are read without a prompt in every role, and a background sub-agent still working after the turn ended gets the role's normal answer instead of a silent refusal of every tool.
- Switchboard no longer quits with a crash when a chat's text changes while the pointer is over the transcript: the hover lookup no longer runs mid-edit, when the message list and its text ranges briefly disagree.
- Scrolling to the end of a chat while another chat is working no longer snaps the bounce back to the edge for one frame.
- Claude chats: a message sent after Stop no longer looks unanswered when the restarted Claude Code first reports a stopped background task; the reply now shows in the chat.
- The chat and the message field also always use the thin overlay scroll bar: the light track with a divider line beside the conversation is gone.
- Scrolling in a chat stays smooth at the edges: the text no longer jumps back for a frame during the bounce past the end, and the copy button of the message under the pointer no longer disappears while scrolling.
- Claude chats whose role allows sub-agents can send follow-up instructions to their own running or finished sub-agents (SendMessage); messages to other Claude sessions stay blocked.
- Scrolling fast to the end of a long chat no longer overshoots into blank space below the last message and snaps back.
- Scrolling right after opening a long chat no longer stutters while older messages fill in.
- Long chats and previewed documents no longer keep a CPU core busy after scrolling (automatic spelling, grammar and substitution checks are off in read-only transcript text).
- After an agent restart, browser_close with the earlier session's token quits the chat's Chrome again: it waits until Chrome actually removes the closed tab before the idle check (which used to keep Chrome open because of that same tab), and a repeated close of an already closed tab no longer fails with session_not_owned but lets an idle Chrome quit.
- Long-running answers write far less to disk: a chat that keeps recording rewrites its stored transcript at most every 10 seconds, and at once when the answer finishes, on chat switch, archive, deactivation, sleep and quit.
- Long-running Claude answers write far less to disk: the chat's session record is saved at most every 10 seconds while the answer streams instead of every second, and at once when the turn starts, finishes or the app quits.
- The sidebar's project list always uses the thin overlay scroll bar: with "Show scroll bars: Always" or a mouse connected it no longer draws a light track that takes a column of the sidebar's width.
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
