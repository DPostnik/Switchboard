# Permission model

The single reference for roles, project access settings, the command sandbox, the external boundary
and approvals. Read it before any change in these areas, including a one-line fix. If a change makes
a statement here false, update this file in the same commit.

State described: 2026-11-12. Sections 1-4 are the model and change rarely. Section 5 is the current
implementation state and changes with every delivered step.

Sources this file condenses (local, not in git; read them only for history and evidence):
`docs/handoffs/permission-runtime-2026-11-11/decision.md` and `solutions.md` (nono decision),
`docs/handoffs/claude-boundary-2026-11-12/plan.md` and `handoff.md` (Claude plan v3),
`docs/harness-permissions.md`, `docs/research/permissions-audit-2026-11-11/report.md`,
`docs/improvements.md`. Where one of them disagrees with this file, this file wins; fix the conflict
here or ask the user.

## 1. The model

**The user decides the boundary once. Inside it the agent never waits. Outside it the agent is
refused with a reason it can read. The agent never receives a wider boundary because a command
failed.**

- The boundary of a chat = its role + the project's settings (folders, access sets, trusted
  commands, command sandbox switch) + the app-level folders for every project + the chat's add-ons.
- Only the user changes these settings. An agent may write a settings proposal
  (`$SWITCHBOARD_SETTINGS_PROPOSALS`, `SettingsProposals.swift`); the app shows it and applies it only
  on the user's click.
- The target is zero prompts for ordinary work. A prompt is kept only where the role says so
  (section 4). A new prompt is a regression; a silently widened grant is a worse one.

### The four channels

Every operation an agent performs goes through exactly one of these. A fix chooses a channel; it
does not invent a fifth.

| # | Channel | For what | Who holds the authority | Example |
| --- | --- | --- | --- | --- |
| 1 | Inside the boundary | Ordinary work: files in the granted roots, shell, builds, tests, the project's own `.mcp.json` servers | The OS sandbox, compiled from the role and project settings | `zsh scripts/test.sh`, `swift build`, edits |
| 2 | Mediated command | A command that needs something the session must never hold: the Keychain, a credential, its own network policy | The nono broker; the policy is per command and comes from an access set | `codesign`, `security`, `gh`, `git push` |
| 3 | App-owned tool | An operation on app or host state: browser, chats, user Chrome, process list, load, unified log, app restart | Switchboard itself, outside the boundary, behind the MCP relay; per-chat scope and consent | `browser_*`, `inspect_chat`, `project_diagnostics` |
| 4 | Settings proposal | Anything the user has not granted yet: another folder, an access set, a trusted command | The user | `addFolders`, `addPresets`, `addCommands` |

Rules for the channels:

- Channel 1 is the default. Code the agent can edit (project scripts, build scripts) always runs in
  channel 1, also after the script changes. Never move a build or a project script outside the
  boundary to make it pass.
- Channel 2 is never a shell or an interpreter. A shell cannot carry extra rights in nono's model.
- Channel 3 tools have a fixed operation and typed arguments. They accept no command line, no
  arbitrary path and no code. The app checks the chat's role and project before it acts. "The agent
  asks Switchboard and Switchboard performs it" means this channel, not a forwarder for failed
  commands.
- Channel 4 is the only way a boundary gets wider.

### After a refusal

Decided by the user on 2026-11-12. A refusal must cost one step, not twenty minutes of workarounds.

1. A refusal names the standard route when the app knows one: the app-owned tool to use, or the
   setting to request. A bare `Operation not permitted` is a defect in the refusal, not in the agent.
2. One refusal, one request. If the agent knows the standard tool, it uses it. If not, it sends one
   access request (channel 4) with the exact folder, access set or command and the reason. It does
   not search for another command, interpreter, path or flag that reaches the same effect: a
   workaround is a boundary bypass, even when it succeeds.
3. The agent continues the independent part of the task while the request waits, and reports the
   request in its final message if it is still open.
4. The user answers once, on the request card in the requesting chat. The grant is a project
   setting, so no later chat asks again. After the answer the app queues one fixed message to that
   chat; its next turn starts the provider process with the new rights and continues the same task
   (built, unit-tested; see section 5).
5. A request that repeats across projects for a safe standard resource becomes a default (an access
   set or a role default), found by the review in section 7. It must not stay a per-project grant.

## 2. Terms

Use one term for one concept, in code comments, copy and reports.

| Term | Meaning | Code |
| --- | --- | --- |
| Role | Named permission profile: Reader, Editor, Developer, Routine operator, Operator | `AgentRole`, `AgentRoleCatalog` (`AgentRoles.swift`) |
| Profile | The resolved rights of one chat | `AgentPermissionProfile` (`AgentContract/AgentPermissions.swift`) |
| Project folders | Extra roots a project declares, read-only or writable | `AgentPermissionProfile.Root` |
| Shared roots | App-level folders for every project, opt-in, empty by default | `SavedState.sharedRoots`, `SharedRootsSettings.swift` |
| Access set | A named bundle of shell paths and trusted commands (github, swift, apple-signing, ...) | `AccessPreset` (`AccessPresets.swift`) |
| Command sandbox | Per-project switch and the shell grants compiled from folders and access sets | `AgentPermissionProfile.CommandSandbox`, `Project.commandSandbox` |
| Trusted command | A literal command prefix from an access set or the project settings | `CommandSandbox.unsandboxed`, `AgentCommandPolicy` |
| External boundary | The nono OS sandbox around the whole provider process tree | `ExternalSandbox.swift`, `NonoRuntime/` |
| Mediated command | A command the nono broker runs with its own grants | `ExternalSandboxCommand` |
| Relay | The socket that connects a sandboxed provider to app-owned MCP servers outside | `SandboxRuntime/mcp_host.py`, `mcp_relay.py` |
| CLI sandbox | Claude Code's own Seatbelt sandbox for Bash (the path Claude uses today) | `ClaudeLaunchPolicy.sandboxSettings` |
| Add-on | An extra right a chat adds to its role: mail and connectors, My Chrome | `RoleAddOn` |
| Ledger | The audit record of every asked, allowed and denied decision, with a `reason` | `CapabilityLedger.swift`, `AgentCapabilityRecord` |

`scripts/check-agent-boundary.py` checks the module boundary of `AgentContract`. It is unrelated to
the external boundary.

## 3. Invariants

A change that breaks one of these is wrong, whatever it fixes.

Authority
1. `AgentPermissionProfile` and the role catalog are the only authority. Enforcement code compiles
   them; it never adds rights of its own. A model cannot create a grant.
2. Roots, cookie sites and approved MCP servers come from the project and the app settings, never
   from the agent, the command text or the current directory. Generated policy uses absolute,
   canonical roots. No `--allow-cwd`.
3. Shared roots and project folders reach only roles with `acceptsExtraRoots` (Developer, operators).
   Editor and Reader never get them. `~` and the app data folder are refused as roots.
4. Policy files, the relay server list and nono state live outside every agent-writable root
   (`~/Library/Application Support/Switchboard-sandbox/workers/<id>/`). A grant that contains this
   state is dropped, never widened.

Enforcement
5. Never answer an approval request automatically from a text heuristic, an observation or a prompt
   string. The app answers only from the profile (roots, tool set, role lists) or from a field the
   provider itself sets (for Claude Bash: `dangerouslyDisableSandbox`).
6. Never widen file-tool roots to make a shell command pass. Access-set paths are for commands.
7. Never write shared or global provider rules (`~/.codex`, `~/.claude`, project `.codex/rules`) to
   grant a chat something. They leak to other chats, roles and the user's own CLIs.
8. A nested-sandbox failure is fixed by turning the inner sandbox off (`--disable-sandbox`,
   `-Xfrontend -disable-sandbox`, the CLI's `sandbox` setting) while the external boundary stays.
   Never by removing the outer one or granting the home folder.
9. The external boundary is used only when it is eligible (`ExternalSandboxPlanner.eligibility`).
   Otherwise the chat falls back to the provider's native path with prompts. The fallback is logged
   and visible; it is never an unrestricted run.
10. A settings or role change replaces the affected provider process. Revocation stops the old
    process group and its descendants before the new rights are claimed. Other chats keep their
    approvals.

Secrets
11. Credentials are never copied between homes and never reach an agent-readable place: not
    arguments, environment, files inside the grants, logs or the ledger. The session has no
    Keychain; only a mediated command or the app reads it.
12. Secret paths (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `.env*`, provider credential
    files) stay denied inside every restricted role.

Process
13. Never retry a turn, an answer or an action after an uncertain transport result.
14. Both providers are checked for every change. A rule added for Claude is added for Codex in the
    same change, or the gap is written into section 5.
15. Every `asked`, `allowed` and `denied` answer records a `reason`. A new reason value updates
    `.agents/skills/access-review` in the same commit.
16. App-owned copy (denial texts, notices, settings) ships in Russian and English.

## 4. Decisions already taken

Do not reopen these without the user.

- nono (pinned, bundled, vendor signature verified before each use) is the external boundary. No
  custom broker, no Docker, no runtime download of the helper.
- Session rights are the union of the project, its folders and its access-set paths. Mediation is
  only for Keychain and network-identity commands (`solutions.md`, option 1).
- Roles, at the level a fix needs:

  | Role | Files | Shell | Network | Prompts |
  | --- | --- | --- | --- | --- |
  | Reader | read-only, writes only in `research/` | off | on | never |
  | Editor | project only, no extra roots | sandboxed (off for Claude) | off | only writes outside the project |
  | Developer | project + folders + shared roots | on | on | only the ask list |
  | Routine operator | project + folders + shared roots | on | on | blocked: a run never waits |
  | Operator | unrestricted | on | on | never; no boundary |

  Routine operator is in audit mode: the engine runs with the unrestricted profile
  (`AgentPermissionProfile.effective`) and the role's denials are only recorded as `wouldDeny`. It
  is therefore not under the external boundary today.

- Developer keeps asking for `rm -r`, `git reset --hard`, `git clean`. Developer is denied, with a
  reason and without a prompt: `sudo`, `launchctl`, `defaults write`, `diskutil`, `security`,
  `git push --force`, `osascript`.
- `osascript` under the boundary only as a mediated command enabled in the role (off by default).
  `pkill` and `screencapture` are not trusted and not mediated.
- Shared roots are opt-in. Nothing is granted until the user adds a folder.
- For Claude Bash the CLI's own `dangerouslyDisableSandbox` flag is the sandbox decision. No text
  heuristic (the removed `runsSandboxed`) comes back.
- Under the boundary an action outside the roots fails; the command itself is never asked about.
  The agent then follows "After a refusal" in section 1: one access request for a durable project
  setting, no workaround (user decision 2026-11-12; it refines the earlier "fails, not asked").
- Grants are reviewed about twice a week (section 7). Accumulated grants are not trusted forever.
- Sub-agents inherit the parent's rights. The role cap limits their tool names only; there is no
  read-only promise for them.
- A project whose trusted commands nono cannot mediate is ineligible for the boundary until those
  commands are removed, mediated or replaced by an app-owned tool.

## 5. Current state (2026-11-12)

| | Codex | Claude |
| --- | --- | --- |
| Enforcement for eligible Developer chats | External boundary (nono), since 2026-11-11, commit 2cddfce | External boundary (nono), phase B2+B3 (commit 524ba0e, verified live in super-wiki 2026-11-12) + the role's command hook; the phase A CLI sandbox remains the fallback |
| Prompts for commands | None: `externalSandbox`, `approvalPolicy: never` | Under the boundary none except the role's ask list (hook); ledger reason `boundary`. On the fallback: as phase A (CLI sandbox, `trusts`, ask or deny) |
| File tools | Share the session union (approximation: access-set paths are writable to them) | Answered by roots in `permission()` (inner check, stricter than the session union); under the boundary a path outside is denied without a prompt, reason `outsideBoundary`, text names the settings proposal |
| Leaving the sandbox | Not possible; mediated commands and relay tools only | Under the boundary not possible (`dangerouslyDisableSandbox` changes nothing); mediated `pgrep`, `codesign`/`security`, `gh`, `git` by access set. On the fallback: flag + trusted command |
| App-owned tools | Through the relay. `project_diagnostics` (diagnostics server) for every role with a shell; `app_log` and `request_app_restart` only where the running app bundle lies inside the project | Under the boundary through the relay (`switchboard_browser`, chat directory with `project_diagnostics`, `app_log`, `request_app_restart` under the same gates); project `.mcp.json` servers inside. On the fallback: direct |
| Access requests (channel 4) | Under the boundary: the inbox is a writable grant, `$SWITCHBOARD_SETTINGS_PROPOSALS` is set, the format instructions are given, `chat` = `CODEX_THREAD_ID`. Native path: none | Inbox writable in the CLI sandbox and under the boundary, `chat` = `SWITCHBOARD_CHAT_ID` |
| Request card and continuation | A proposal whose `chat` names an existing, unarchived, non-scheduled chat is a card in that chat (Apply, Reject; waiting state in the sidebar, Needs you, palette, dock, notch and Fringe). Apply saves the settings, removes the file, queues one fixed message; Reject removes the file, queues one fixed rejection. Only a removed file continues its chat, once. Other proposals keep the global sheet | Same (shared code in `DeskModel`) |
| Credentials | `CODEX_HOME` auth file inside the provider home | The app reads its profile's Keychain item with `/usr/bin/security` outside; the bare token goes as the first stdin line to a zsh launcher that moves it to fd 3 (option d). The CLI cannot refresh it: a live worker is replaced at the next turn once less than 30 minutes remain; a launch with a missing or expiring token falls back to the CLI sandbox, whose CLI renews the Keychain item itself (assumption, unverified live) |
| Ineligible cases | Operator role, role without network, command sandbox off, helper not verified: native sandbox with prompts | Codex's cases, plus: a trusted project command the boundary cannot run (inventory), the user's Chrome (`--chrome`) enabled, token missing or expiring. Visible RU/EN chat notice, once per session and reason; role-defined cases (unrestricted, no network) only logged (`externalSandbox`) |
| Revocation | A changed scope replaces the worker at the next send | A changed plan authority or launch replaces the process at the next turn: process group SIGTERM, wait up to 3 s, SIGKILL, relay host stopped, worker folder removed, then the new process; per-session epoch for pending interactions. A running turn is not stopped by a settings change (both providers) |

Claude phases B2+B3 were published as `524ba0e` (with the relay fix: app-owned servers start in the
project folder, for both providers) and verified live in super-wiki on 2026-11-12: environment
marker, project writes without a prompt, a read outside refused with reason `outsideBoundary` and
the route text, resume after an app restart, browser tools through the relay. Not yet run: the live
scenarios with five parallel chats, a settings change during a chat, a token-expiry relaunch and the
My Chrome fallback notice. `scripts/probe-claude-nono.py` check 6 (sub-agent teardown) reports
`fail`: it matches tracked processes by the launcher's process group, but the CLI starts each
background Bash task in its own group. The plan and the brief are in
`docs/handoffs/claude-boundary-2026-11-12/` and `docs/handoffs/permission-model-2026-11-12/`.

Steps 2-4 of the permission-model handoff (commits `233be8b`, `6b14264`, `f0a8fde`,
2026-11-12) are unit-tested only: tests were written but not run in the authoring chats,
and nothing of them is checked live yet.

Rollback switch for the Claude boundary: `defaults write local.daniil.switchboard ClaudeExternalBoundaryOff -bool YES`,
then restart the app; Claude chats return to the CLI sandbox.

Delivered in steps 2-4 (each still waits for the live check):

- Verification queue under the boundary: `scripts/verify-project.py` reads the load from the kernel
  (`os.getloadavg`, `os.cpu_count`) and counts heavy jobs with `ps` only where `ps` runs; under the
  boundary it skips the count and says so, and the shared build lock still runs builds one at a
  time. Under the boundary `install` does not run the restart script: it records the attempt and
  tells the agent to call `request_app_restart` once. Builds and tests stay in channel 1.
- `request_app_restart` (`ChatDirectoryRuntime/server.py`): posts the app's own restart notification
  once per chat server, no arguments, no retry, also after an error; the continuation goes to the
  requesting chat by its Switchboard chat ID (both providers, when the chat directory server is
  attached) or, on Codex's diagnostics-only server, by its Codex thread ID. It never starts the
  app binary (the bundle lies in an agent-writable project). `scripts/request-app-restart.sh`
  remains for chats without the tool; under the boundary it cannot reach the running app.
- `app_log`: a fixed `log show` argv run by the server outside the boundary, predicate on the app's
  subsystem, category from a fixed list, 5 to 60 minutes, up to 300 lines, long lines cut,
  credential-like text redacted. With it, this project's Claude chats can move under the boundary
  once the user removes `/usr/bin/log show` from the trusted commands (the only inventory blocker
  here) and `zsh scripts/request-app-restart.sh` (not a blocker, but useless under the boundary).
  This is a settings proposal only the user applies; not applied on 2026-11-12.
- Settings proposal inbox for Codex chats under the boundary (writable grant, variable,
  instructions). The native Codex path still has none (it keeps its file roots, invariant 6).
- Access request card in the requesting chat and continuation after Apply or Reject (table above).
- The "After a refusal" rule is in `AgentAutonomy`, which every chat of every project gets (Claude
  chats, Claude scheduled jobs, Codex threads), RU and EN. The heavy-work rule there names
  `project_diagnostics` first and no longer tells Claude to leave the sandbox for `sysctl`.
- Refusal texts that name the route (Claude): the role deny list (`denyList`: no workaround; the
  browser tools for `osascript`, `request_app_restart` for `launchctl`; report to the user), every
  `unattended` refusal including the hook's unattended ask-list hit and the unattended unsandboxed
  command (one settings proposal when the inbox exists, the blocker in the final message), and
  `shellOff` (no other way; only the user changes the role). Decisions and ledger reasons did not
  change.

Codex chat inspection (2026-11-12, implementation pending verification): channel 3 uses the same
`ChatDirectoryRuntime` reference allowlist as Claude. Directory arguments are part of the dedicated
worker scope; adding or revoking the server replaces only that worker before submission.
No role, root or automatic approval grant changes. See `docs/codex-chat-inspection.md`.
First-turn scope follow-up (2026-11-12): reserve the chat ID and its diagnostics/reference-only
server arguments before creating a provider session. Both providers receive the same scope at
creation and first submission; Codex must not release an unsaved empty thread merely to attach
those tools. Channel 3, unchanged allowlist and boundary; no replay of failed messages.
Follow-up (2026-11-12): disabling the duplicate diagnostics server must retain a valid stdio
transport (`/usr/bin/false`, empty arguments, disabled and not required); Codex validates even
disabled entries. Channel 3 only; no grant or retry behavior changes. Verification pending.

Known gaps. Check this list before you treat a failure as a new defect.

- `scripts/build-app.sh` and the queue's `confirm-live` read the process list and a process's path and
  start time through libproc instead of `ps` (2026-11-12): `ps` stopped the app build after a
  successful compile under the boundary. libproc sees every process there.
- Mediated `git` (2026-11-12): `/usr/bin/git` is Apple's `xcrun` shim and cannot start inside a
  mediated sandbox (`couldn't stat Xcode's Info.plist`; seen live in this project, where every git
  command failed under the boundary). The planner now mediates the real binary (`resolveGit`:
  Homebrew's git, else `xcrun --find git`). The Homebrew shape is the one the runtime probe checks;
  the live check of the fix under the boundary is pending.
- Under nono `ps` cannot run (setuid) and `log show` cannot run in any sandbox: use
  `project_diagnostics` and `app_log`. `pgrep` sees only sandboxed processes unless mediated.
  `lsof -i` and `sysctl -n vm.loadavg` work.
- `app_log` and `request_app_restart` reach only chats whose project contains the running app
  bundle. A chat in a separate worktree (also `.claude/worktrees/*` of this project) does not get
  them: the bundle is not inside the worktree. Such a chat uses the script and `/usr/bin/log show`
  where its sandbox allows them, otherwise it reports the blocker.
- A new Codex thread has no thread ID when its diagnostics server starts, so its restart request
  restarts the app but continues nothing; after the thread is resumed (its next server start) it
  carries the ID.
- `scripts/request-app-restart.sh`, `scripts/prepare-nono.py` (needs the certificate chain; run it
  outside a sandbox) and so `scripts/build-app.sh` as a whole are unverified under the boundary.
- job-search's trusted `launchctl` and `cp … ~/Library/LaunchAgents/` keep its Claude chats on the
  CLI sandbox (inventory); no app-owned tool covers them.
- The command inventory (`ExternalSandboxPlanner.unrunnableTrustedCommand`) is used by Claude only.
  Codex does not apply it yet (invariant 14 gap, waiting for the user's decision): it would take
  this project's Codex chats off the boundary they use today because of the trusted `log show`.
  The base entries `ps` and `sysctl -n` are exempt for both.
- Mediated `pgrep` is a Claude planner input only; Codex chats under the boundary do not have it.
- Codex shows no chat notice when it falls back to the native sandbox; the reason is only logged.
- Claude's own Claude in Chrome bridge (`--chrome`) is not verified under nono, so chats with the
  user's Chrome stay on the CLI sandbox.
- Access requests: the card does not reach the mobile app. A proposal without a valid chat (none,
  unknown, archived, a scheduled run) keeps the global sheet and continues nothing. A running turn
  is not interrupted: the new rights apply from the next turn.
- Refusal texts without the route: Claude `outsideRoots` on the CLI-sandbox path, `network` (role
  without network, in `permission()` and the hook), `connectorScope`, `turnEnded`,
  `unsupportedTool`, `notOwnSubagent`. Codex: the app answers approvals with protocol decisions
  (`decline`, `cancel`) that carry no text, and an engine refusal under `approvalPolicy: never`
  has no app text. A nono OS refusal carries no text for either provider. These paths are covered
  only by the `AgentAutonomy` rule. ACP (Gemini) refusals are unchanged.
- Grants carry no origin: the settings do not record when, by which chat and why a folder or command
  was added, and nothing reports a grant that is never used.
- Roles without network stay on the native path (the proxy allowlist for model hosts is not wired).
- `git worktree add ../sibling` is outside the git grant.
- Requests outside an active turn (background sub-agents) get the role's own answer; what would
  need the user is refused.

## 6. How to fix a defect in this area

1. **Capture the real failure first.** `inspect_chat` or `zsh scripts/chat-lookup.sh <ID>` for the
   chat; the ledger row and its `reason`; the exact error text. Classify it:
   - a prompt was shown (`asked`, `hookAsked`);
   - the app refused (`denied`, `hookDenied`, `unsupportedTool`);
   - the OS refused inside a sandbox (`Operation not permitted`, exit 1 with no ledger row);
   - the fallback path ran (log category `externalSandbox`).
   Do not write code from a guess about which one it was. Read the installed provider version's
   contract, not a summary of it.
2. **Name the operation, then its channel** (section 1):
   - ordinary project work that the user already granted → channel 1: fix how the grant is compiled
     (`ExternalSandboxPlanner`, `Project.commandSandbox`, `ClaudeLaunchPolicy`), for both providers;
   - needs the Keychain or a credential → channel 2: a mediated command tied to an access set;
   - reads or changes app or host state → channel 3: a narrow app-owned tool, shared by both
     providers;
   - the user never granted it → channel 4: a readable refusal and a settings proposal. No code
     change grants it;
   - on a deny list → it stays denied; improve the reason text if the agent could not act on it.
3. **Check the invariants** in section 3 and the decisions in section 4. If the fix needs one of
   them changed, stop and ask the user with the concrete case.
4. **Keep the fix as small as the defect.** One shape in `AgentCommandPolicy`, one grant in the
   planner, one tool. No second policy layer, no new permission vocabulary.
5. **Verify** (section 8), then update section 5 if the state or a known gap changed.

Wrong fixes that were proposed or shipped before, and why:

| Wrong fix | Why it is wrong | Right direction |
| --- | --- | --- |
| Add `ps` to the trusted commands | A trusted command does not pass the external boundary; `ps` cannot run there at all | Channel 3: diagnostics tool |
| Run the whole verification queue outside the boundary | The queue runs project scripts the agent can edit: a sandbox escape named "build" | Only load and process facts move to channel 3 |
| Put a nono policy on `/bin/zsh` to give the shell cache rights | A shell is not an authority carrier; nono denies its direct exec | Session union for paths, mediation for Keychain commands |
| Guess from command text whether the CLI sandboxes it (`runsSandboxed`) | Wrong in both directions: false prompts and one unsandboxed command allowed | The CLI's own flag |
| Answer approval callbacks automatically after "observing" a match | Observation is audit, not authority | Remove the prompt by establishing the boundary |
| Add project folders to Codex writable roots for a cache | File tools get the same write | Access-set path in the session union, recorded as an approximation |
| Pass the Claude token in an environment variable | Agent Bash reads it through `sysctl KERN_PROCARGS2` | fd 3 through the launcher |
| Tests built from the adapter's own constants | They pass while the real provider message differs | A fixture copied from a sanitized real message |

## 7. Grant review

Every answered request widens a project for good, so the settings are reviewed on a schedule
(target: twice a week) with the `access-review` skill. The review only proposes; the user applies.

- **Remove:** a grant no chat used in the review window; a grant wider than its use (a folder where
  one subfolder is used, writable where only reads happen, a command prefix that also matches a
  destructive form); anything from the skill's "do not grant" list that got in.
- **Narrow:** replace single commands and folders with an access set when one covers them.
- **Promote:** the same safe grant in several projects becomes a default, so it stops being asked.
- **Report:** refusals followed by a retry of the same command (`denied_then_retried`) and long
  turns after a refusal. They show a missing default, a missing app-owned tool or an agent that
  ignored "After a refusal".

Removals go out as settings proposals (`removePresets`, `removeFolders`, `removeCommands`), one rule
per file, and are recorded in `docs/access-reviews.md`.

## 8. Verification

- Tests: `zsh scripts/test.sh --filter` with the files that cover the change. The set for this area:
  `AgentRoleTests`, `AgentCommandPolicyTests`, `CommandSandboxTests`, `ExternalSandboxTests`,
  `ClaudeInteractiveTests`, `CodexWorkerIsolationTests`, `AgentPermissionSupportTests`,
  `SettingsProposalTests`, `CapabilityLedgerAuditTests`, `RoleAddOnTests`. Every new allowed shape
  gets negative tests beside it.
- Boundary changes: the probes, run outside any enclosing sandbox:
  `scripts/probe-nono-runtime.py`, `scripts/probe-codex-nono.py`, `scripts/probe-claude-nono.py`.
  A probe that could not run is a blocker, not a pass.
- Skill script: `python3 scripts/test-access-review.py` when the ledger schema, decision values or
  access sets change.
- Live, in the running app, for both providers: a new Developer chat and a resumed one perform the
  fixed operation with zero prompts; one action outside the boundary is refused with the reason;
  the ledger rows carry the expected `reason`.
- Record the result in `docs/improvements.md`. State what was not checked.

## 9. Code map

| Area | Files |
| --- | --- |
| Profile and support declarations | `Sources/AgentContract/AgentPermissions.swift` |
| Roles, add-ons, resolution per chat | `Sources/ContextCore/AgentRoles.swift`, `Sources/ContextDesk/DeskModelPermissions.swift` |
| Access sets, command sandbox compile | `Sources/ContextCore/AccessPresets.swift` |
| Trusted-command matcher | `Sources/ContextCore/AgentCommandPolicy.swift` |
| External boundary: helper check, planner, policy, launch, teardown | `Sources/ContextCore/ExternalSandbox.swift`, `NonoRuntime/`, `scripts/prepare-nono.py` |
| Relay for app-owned MCP servers | `SandboxRuntime/` |
| Codex wiring | `Sources/CodexAdapter/CodexIntegration.swift` (`boundary`), `CodexClient.swift`, `CodexConnection.swift`, `CodexConfiguration.swift` |
| Claude wiring | `Sources/ClaudeAdapter/ClaudePermissions.swift` (`ClaudeLaunchPolicy`), `ClaudeIntegration.swift` (`permission()`, `hook()`) |
| App-owned tools | `ChatDirectoryRuntime/server.py` (`inspect_chat`, `project_diagnostics`, `app_log`, `request_app_restart`; gate `ChatDirectory.hostApplication`, restart continuation `AppRestart.swift`), `BrowserRuntime/`, `UserChromeRuntime/` |
| Settings proposals | `Sources/ContextCore/SettingsProposals.swift` (inbox, shared instructions, `SettingsProposalOutcome`), `Sources/ContextDesk/SettingsProposalView.swift` (card and sheet), `DeskModel.swift` (apply, reject, continuation) |
| Settings UI | `Sources/ContextDesk/ProjectSettingsView.swift`, `ProjectPermissionsView.swift`, `SharedRootsSettings.swift` |
| Ledger and review | `Sources/ContextCore/CapabilityLedger.swift`, `Sources/AgentContract/AgentRuntimeEvents.swift`, `.agents/skills/access-review/` |
| Agent-facing instructions and refusal texts | `Sources/ContextCore/AgentAutonomy.swift`, `sandboxCommandInstructions` in `ClaudeIntegration.swift`, `boundaryCommandInstructions` and the refusal texts in `ClaudeBoundary.swift` |
| Build under the boundary | `scripts/swift-task.py` (`SWITCHBOARD_EXTERNAL_SANDBOX`) |
