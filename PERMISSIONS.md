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
  commands, named Keychain items, command sandbox switch) + the app-level folders for every project
  + the chat's add-ons.
- Only the user changes these settings. An agent may write a settings proposal
  (`$SWITCHBOARD_SETTINGS_PROPOSALS`, the chat's own folder, `SettingsProposals.swift`); the app
  shows it and applies it only on the user's click.
- The target is zero prompts for ordinary work. A prompt is kept only where the role says so
  (section 4). A new prompt is a regression; a silently widened grant is a worse one.

### The four channels

Every operation an agent performs goes through exactly one of these. A fix chooses a channel; it
does not invent a fifth.

| # | Channel | For what | Who holds the authority | Example |
| --- | --- | --- | --- | --- |
| 1 | Inside the boundary | Ordinary work: files in the granted roots, shell, builds, tests, the project's own `.mcp.json` servers | The OS sandbox, compiled from the role and project settings | `zsh scripts/test.sh`, `swift build`, edits |
| 2 | Mediated command | A command that needs something the session must never hold: the Keychain, a credential, its own network policy | The nono broker; the policy is per command and comes from an access set; an argument allow-list where the command could reach more than it needs | `codesign`, `security find-identity`, `gh`, `git push` |
| 3 | App-owned tool | An operation on app or host state: browser, chats, user Chrome, process list, load, unified log, app restart | Switchboard itself, outside the boundary, behind the MCP relay; per-chat scope and consent | `browser_*`, `inspect_chat`, `project_diagnostics` |
| 4 | Settings proposal | Anything the user has not granted yet: another folder, an access set, a trusted command, a named Keychain item | The user | `addFolders`, `addPresets`, `addCommands`, `addKeychainItems` |

Rules for the channels:

- Channel 1 is the default. Code the agent can edit (project scripts, build scripts) always runs in
  channel 1, also after the script changes. Never move a build or a project script outside the
  boundary to make it pass.
- Channel 2 is never a shell or an interpreter. A shell cannot carry extra rights in nono's model.
- A mediated command that can reach the whole Keychain (`security`) carries an argument allow-list
  (nono `invocation_policy`, default deny): only the listed argument forms run, everything else is
  refused by nono.
- Channel 3 tools have a fixed operation and typed arguments. They accept no command line, no
  arbitrary path and no code. The app checks the chat's role and project before it acts. "The agent
  asks Switchboard and Switchboard performs it" means this channel, not a forwarder for failed
  commands.
- Channel 4 is the only way a boundary gets wider.

### After a refusal

Codex 0.167.0 delivery (2026-11-15): the existing developerInstructions override does
not update an established resumed model context. The adapter also sends the same
fixed app-owned guidance through turn/start additionalContext application fragments
(developer authority), gated to this exact checked protocol. UTF-8 chunks preserve
the provider's 1,000-token per-value cap. No user input, permission, grant or retry
policy changes. Cold resume may repeat the current update once; compaction rebuilds
the current configured developer bundle. Runtime instruction mutation without worker
replacement is outside this contract. Live verification remains required.

Decided by the user on 2026-11-12. A refusal must cost one step, not twenty minutes of workarounds.

1. Classify the exact error before choosing a route: command-policy denial, missing resource, or
   known nested-sandbox startup incompatibility. Bare `Operation not permitted` alone does not
   identify a missing folder or access set. Preserve the exact error and the active boundary facts.
2. For a real command or resource denial, use the standard app-owned tool when available. Otherwise
   send one access request (channel 4) only for an identified missing grant that can resolve the
   failure; report other blockers without speculative broad grants. Do not search for another
   command, interpreter, path or flag with the denied effect. Denied deletion (`rm -rf`) uses an
   explicit approved route when available; otherwise report the blocker. Never use an alternate interpreter. Narrow exception (invariant 8):
   with confirmed `SWITCHBOARD_EXTERNAL_SANDBOX=1`, proactively use SwiftPM `swift build
   --disable-sandbox` / `swift test --disable-sandbox`, or the existing project wrapper. This is
   channel 1: only the inner SwiftPM sandbox is disabled; nono and every external grant stay.
   The known `sandbox-exec: sandbox_apply: Operation not permitted` during manifest-evaluation
   startup permits this correction only before build, test or plugin execution starts. No uncertain
   action is replayed. Without confirmed external enforcement, do not disable the sandbox.
   Other EPERM, file, network, command-policy and PostgreSQL `shmget` failures are excluded.
   PostgreSQL needs a separately available, authorized isolated test database; otherwise report
   the blocker, never broader grants, the user's database or removal of the external boundary.
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
   Only with confirmed external enforcement; see the narrow SwiftPM startup rule above.
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
    Keychain; only a mediated command or the app reads it. One deliberate exception (user decision
    2026-11-12): a named Keychain item the user granted to a project (`Project.keychainItems`) is
    readable by that project's agents through the mediated `security find-generic-password` forms.
    Per item, visible and removable in the project settings, listed by the grant review; never the
    whole Keychain and never a reserved item (`KeychainItemRule.reserved`).
12. Secret paths (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, project env files `.env` and
    `.env.<suffix>` at any depth of every granted folder, provider credential files) stay denied
    inside every restricted role. The env file templates `.env.example`, `.env.sample`,
    `.env.template` hold no secrets and stay open (`ProjectSecretFiles`, 2026-11-21; under the
    boundary for the whole process tree, see section 5). One deliberate exception (user decision
    2026-11-13): mediated gh's own sandbox reads `~/.config/gh` (read-only), only while its
    `hosts.yml` holds no plain-text `oauth_token` (the token stays in the Keychain). The session and
    every other command never get it. Second exception (user decision 2026-11-20): the `docker` access
    set opens the Docker daemon socket file inside `~/.docker` (`--allow-unix-socket` plus
    `--bypass-protection` on that one file); the folder and `config.json` stay denied.

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
- Named Keychain items (2026-11-12): a project may be granted single generic-password items (service,
  optional account). The agent asks with `addKeychainItems` and the reason; the user applies once on the
  request card; later chats of that project are not asked. Enforcement is nono's argument allow-list on
  the mediated `/usr/bin/security` (exact `find-generic-password` forms, default deny), not an app
  helper or an approval backend. The whole Keychain is never granted. Only the project settings fill the
  list (`Project.commandSandbox(extraRoots:)`), so Reader and Editor never get it.
- Mediated git and gh (2026-11-13): the Keychain only for `push`, `fetch`, `ls-remote` in the exact shapes of section 5;
  agents lose their own command aliases, custom credential helpers, `GIT_SSH_COMMAND`, `GIT_CONFIG_*` injection,
  non-https protocols, `git pull` (use fetch and merge) and `gh auth token`/extensions/aliases. The user's global git
  config stays effective (commit identity). Remote-host pinning is a later step.
- For Claude Bash the CLI's own `dangerouslyDisableSandbox` flag is the sandbox decision. No text
  heuristic (the removed `runsSandboxed`) comes back.
- Under the boundary an action outside the roots fails; the command itself is never asked about.
  The agent then follows "After a refusal" in section 1: one access request for a durable project
  setting, no workaround (user decision 2026-11-12; it refines the earlier "fails, not asked").
- Docker (2026-11-20): only through the `docker` access set, which opens the daemon socket file and
  nothing else in `~/.docker`. Never a folder grant of `~/.docker` or a bypass of a whole folder.
- Project env files (2026-11-21): `.env` and `.env.<suffix>` close at the external boundary for both
  providers, for the session and every mediated command, read and write, files created later and
  nested folders included; only the three templates stay open. Agents reach a project secret through
  a named Keychain item (`addKeychainItems`), never through the file. No mediated command regains it.
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
| Leaving the sandbox | Not possible; mediated commands (`pgrep`, `codesign`/`security`, `gh`, `git` by access set; `security` only `find-identity …` and the exact reads of the project's Keychain items) and relay tools only | Under the boundary not possible (`dangerouslyDisableSandbox` changes nothing); mediated `pgrep`, `codesign`/`security`, `gh`, `git` by access set (`security` only `find-identity …` and the project's Keychain items). On the fallback: flag + trusted command; Keychain items not enforced |
| App-owned tools | Through the relay. `project_diagnostics` (diagnostics server) for every role with a shell; `app_log` and `request_app_restart` only where the running app bundle lies inside the project | Under the boundary through the relay (`switchboard_browser`, chat directory with `project_diagnostics`, `app_log`, `request_app_restart` under the same gates, and since 2026-11-13 `switchboard_user_chrome` for chats with the My Chrome add-on and the app's grant, in place of the CLI's `--chrome`); project `.mcp.json` servers inside. On the fallback: direct, and the user's Chrome is the CLI's own Claude in Chrome bridge (`--chrome`) |
| Access requests (channel 4) | Under the boundary: the worker's own inbox folder is a writable grant and `$SWITCHBOARD_SETTINGS_PROPOSALS` points there; the format has no `chat`. A worker serves one chat for its life, so the folder is the thread ID when the worker starts for an existing thread, else an app token (`codex-<uuid>`) that the app maps to the new thread's ID once `thread/start` returns (`settings-proposals-authors.json`, next to the inbox, outside every grant). Native path: none | The session's own inbox folder, named by its session ID, writable in the CLI sandbox and under the boundary; the format has no `chat` |
| Request card and continuation | The author is the chat whose folder holds the file (`SettingsProposalInbox.load`); a `chat` field in a folder file is ignored. A root file (sessions started before 2026-11-12's per-chat folders) keeps the old rule: its `chat` must name an existing, unarchived, non-scheduled chat. A known author gets a card in that chat (Apply, Reject; waiting state in the sidebar, Needs you, palette, dock, notch and Fringe). Apply saves the settings, removes the file, queues one fixed message; Reject removes the file, queues one fixed rejection. Only a removed file continues its chat, once. Other proposals keep the global sheet, which says in one sentence that the requesting chat is unknown and the task will not continue by itself | Same (shared code in `DeskModel`) |
| Credentials | `CODEX_HOME` auth file inside the provider home | The app reads its profile's Keychain item with `/usr/bin/security` outside; the bare token goes as the first stdin line to a zsh launcher that moves it to fd 3 (option d). The CLI cannot refresh it: a live worker is replaced at the next turn once less than 10 minutes remain (was 30; user decision 2026-11-14); a launch with a missing or expiring token falls back to the CLI sandbox, whose CLI renews the Keychain item itself, but only within 5 minutes of expiry (CLI 2.1.323 source; no command forces it earlier, host refresh is limited to other entrypoints). Known gap: about 5 minutes of fallback per token (CoreSimulator and other Mach services closed there), and a boundary turn longer than its remaining lifetime ends with an authentication error |
| Ineligible cases | Operator role, role without network, command sandbox off, helper not verified, a trusted project command the boundary cannot run (inventory, same planner input as Claude; `ps` and `sysctl -n` exempt): native sandbox with prompts. Visible RU/EN chat notice (`CodexBoundaryNotices`, text from `ExternalSandboxPlanner.fallbackNotice`), once per chat and reason, when a worker starts; role-defined cases (unrestricted, no network, command sandbox off) only logged | Codex's cases, plus: the My Chrome add-on without a grant from the app's own Chrome extension (not installed, not paired, switched off; the chat then keeps the CLI's `--chrome`), token missing or expiring. Visible RU/EN chat notice, once per session and reason; role-defined cases (unrestricted, no network) only logged (`externalSandbox`); command sandbox off is shown |
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

Steps 2-4 of the permission-model handoff were published on 2026-11-12 (`3ace4fc`, `522d4a3`,
`742d4ba`, `0f931ec`, then `429754a`, `a4a2e25`). Checked live in this project, from a Claude chat
under the boundary: the request card with continuation and process replacement (three applied
requests, both directions), `app_log`, `request_app_restart` with its continuation, mediated git
(`status`, `fetch`, `push`), and a whole queue cycle (submit, build, codesign, tests, install,
`confirm-live`, publish). A Codex Developer chat under the boundary (chat 4DA55008, build 495):
marker `1`, mediated `pgrep` and git with no prompt, `ls ~/Documents` refused by the OS, one
proposal written through `$CODEX_THREAD_ID`, the card shown, Reject delivered the fixed message and
the agent stopped with no workaround (0 denied-then-retried). Not checked live: a card during a
running turn, the new refusal texts, the mobile app.

Rollback switch for the Claude boundary: `defaults write local.daniil.switchboard ClaudeExternalBoundaryOff -bool YES`,
then restart the app; Claude chats return to the CLI sandbox.

Rollback switch for the narrowed mediated git and gh (both providers):
`defaults write local.daniil.switchboard ExternalBoundaryGitNarrowingOff -bool YES`; read when a chat's process is planned,
no app restart needed (known gaps below).

Delivered in steps 2-4 (live status in the paragraph above):

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
  The user applied this settings proposal on 2026-11-12: this project's Claude chats run under the
  boundary and the "External boundary unavailable" notice no longer appears for it.
- Settings proposal inbox for Codex chats under the boundary (writable grant, variable,
  instructions). The native Codex path still has none (it keeps its file roots, invariant 6).
- Access request card in the requesting chat and continuation after Apply or Reject (table above).
- The "After a refusal" rule is in `AgentAutonomy`, which every chat of every project gets (Claude
  chats, Claude scheduled jobs, Codex threads), RU and EN. The heavy-work rule there names
  `project_diagnostics` first and no longer tells Claude to leave the sandbox for `sysctl`.
  Follow-up 2026-11-15: shared RU/EN guidance classifies failures before requesting access and
  names the narrow, confirmed-boundary SwiftPM startup correction (channel 1, invariant 8).
  Claude boundary instructions defer to that shared rule; Codex start/resume and Claude chat/job
  wiring already deliver it. No policy, grant, role, tool or ledger change. Source and existing wrapper gating reviewed;
  current build, affected-test and live-validation results are recorded in `docs/improvements.md`.
- Refusal texts that name the route (Claude): the role deny list (`denyList`: no workaround; the
  browser tools for `osascript`, `request_app_restart` for `launchctl`; report to the user), every
  `unattended` refusal including the hook's unattended ask-list hit and the unattended unsandboxed
  command (one settings proposal when the inbox exists, the blocker in the final message), and
  `shellOff` (no other way; only the user changes the role). Decisions and ledger reasons did not
  change. Since 2026-11-21 the `security` deny entry does not refuse the exact read of a project's listed Keychain item
  under the boundary (see "Named Keychain items" in the known gaps); its refusal text for every other form is unchanged.

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

Mobile settings decisions (implemented 2026-11-12, validated 2026-11-13): channel 4 proposals
can be published as pending chat approval cards through the existing authenticated remote database.
The phone sends a host-owned single-use UUID handle (compared by UUID value after database normalization) and an explicit persistent-settings decision marker;
settings are never taken from the remote command. Every target project must be shared, the source
chat must exist and belong to a target, and the reviewed diff and current target settings must still
match. File changes, local decisions, project changes and host restart invalidate old handles.
The mobile review includes named Keychain item warnings and the same command-boundary notes as Mac.
Changed boundary notes invalidate old handles. Oversized or partially skipped requests can only be declined remotely. Applying uses SavedState.apply
and awaits durable saving before success; a save failure is uncertain. Provider identity and role
limits are unchanged for both Codex and Claude. That access-request transport does not itself use APNs. Optional native push delivery is a separate feature described below.
Settings take effect on the next provider launch. Mobile decisions queue the same fixed continuation
as desktop decisions, after a successful save; no proposal-supplied text is sent.

Manual iPhone signing workflow (2026-11-13): `scripts/install-mobile-manual.py` builds unsigned
in channel 1 with the compiler's nested macro sandbox disabled (invariant 8), then calls named
`codesign` in channel 2, using an already-issued profile and its authorized entitlements. It does
not request account access, export a private key, renew profiles, or automatically retry device
installation. Operator build/sign/strict verification/install/launch passed. Developer clean build,
brokered signature and strict verification also passed with the external boundary enabled. Direct
CLI installation remains refused by CoreDevice (artifact Info.plist, NSCocoaErrorDomain 257/EPERM);
installation instead uses the implemented fixed app-owned tool described below. Existing
swift/apple-signing sets are unchanged. See docs/improvements.md for actual results.

iPhone installation (user decision 2026-11-13): Developer must be able to install this project's
app without changing to Operator. Channel 3 adds `install_mobile_app`, no tool arguments, only
when the running Switchboard bundle belongs to this project, a shell/network/project-capable
profile already has Apple signing access (or is unrestricted), and this project's mobile target
exists. Reader/Editor and other projects do not receive the tool. Both providers share the app's
ChatDirectory scope. The fixed artifact is .build/mobile-device/Build/Products/Debug-iphoneos/ContextMobile.app,
with bundle com.contextdesk.mobile, Apple team 4M74WJDNSW and the already-configured iPhone.
The host copies it without following links into its protected Switchboard-sandbox staging root,
rejects symlinks/foreign bundles and verifies its Apple certificate/team/designated app requirement.
It never executes project code on Mac or accepts commands, paths, identities or device IDs.
A durable per-project/device/artifact attempt receipt is saved before CoreDevice dispatch; a lost
reply, timeout or repeat call cannot install it twice. No keys, account sessions or filesystem
grants reach the agent. A nonzero device result is uncertain and is never automatically retried.
This new authority is installation of the fixed signed mobile artifact only; source builds and
signing remain in channels 1 and 2. No existing boundary, grant or approval invariant is relaxed.
Verified live in Developer on 2026-11-13: host installation produced a new device bundle container,
and one subsequent launch succeeded. The 15-second tool wait expired before confirmation;
read-only device state reconciled this attempt, without a second installation. A receipt may
therefore remain uncertain even when installation completed; never retry based on that status.
Native build and 68 selected tests passed. Mobile Decline and fixed chat continuation were verified
live; persistent Apply is covered by automated tests, not claimed as a live UI check.

Every signing project (user decision 2026-11-14): the same channel 3 tool now reaches any project whose
chat profile passes the same role gate (shell, network, project filesystem with the Apple signing set's
`codesign`, or unrestricted), for both providers; the running app no longer has to lie inside the
project. The server, not the agent, picks the artifact: the newest `.app` matching
`.build/*/Build/Products/{Debug,Release}-iphoneos/*.app` in the project (no links on the path). The
app ID is read from the staged bundle and must pass `codesign -R` with team 4M74WJDNSW and that
identifier. The first project that installs an app ID owns it (`bundle-<sha256>.json` beside the
receipts, created exclusively); another project's install of that ID is refused, so a project cannot
replace another project's app on the phone. Device and team stay fixed. Found because isostudio's
Developer chat signed its app under the boundary but direct `devicectl` installation failed with the
same Info.plist EPERM as above.

Known gaps. Check this list before you treat a failure as a new defect.

- Project env files at the boundary (2026-11-21, user decision; `ProjectSecretFiles`, `ExternalSandboxPlan.secretFileRoots`).
  Before, only Claude's settings rules `Read(**/.env)`, `Read(**/.env.*)` existed: they stop Claude's Read tool and Bash
  commands the CLI parses. Seen live in isostudio: Claude's `grep … .env` inside a `for` loop read the file, Codex ran
  `node --env-file=.env` and read `SENTRY_AUTH_TOKEN` (now a Keychain item, commit c7766ab). Now, channel 1, both providers
  through the shared planner:
  - Folders: the project, its folders and shared roots, and every folder grant inside them (the role's scratch folder,
    access-set paths in the project). Not the provider home, temp, toolchains or caches. A root whose path contains `*` is
    skipped (nono would read it as a glob).
  - Session: nono `filesystem.deny` `<root>/**/.env`, `<root>/**/.env.*`. nono 0.81.0 (`crates/nono-cli/src/policy.rs`
    `add_glob_deny_rules`, profile guide "Glob patterns", schema `FilesystemConfig.deny`) expands the glob at start and, on
    macOS, emits a Seatbelt regex deny (`file-read-data`, `file-write*`) that wins over the folder grant and covers files created
    later and any depth (`**/` also matches the root level). Metadata stays visible (`test -e` works).
  - Templates: nono has no typed exception that fits. `filesystem.bypass_protection` reopens only files that exist at start
    and through their canonical path (`apply_deny_overrides`), so a template linked to `.env` would reopen `.env` and a template
    created later stays closed. The policy therefore adds top-level `unsafe_macos_seatbelt_rules` after the deny:
    `(allow file-read-data (regex …/.env.example$))` per root and template, `file-write*` only for read+write roots. Seatbelt
    checks the resolved path (nono relies on it too), so a link named like a template that points at `.env` should stay
    closed (probe check `env-template-link-denied`, not run). nono honours raw rules only
    for profiles loaded by path (`strip_untrusted_unsafe_seatbelt_rules`), which ours is.
  - Mediated commands (channel 2): a command sandbox inherits no agent deny except the Keychain one
    (`tool-sandbox/platform/macos.rs` `build_child_caps`; profile guide on `keychain_access`), and its schema has no deny field.
    Every command sandbox (git, gh, codesign, security, pgrep, git's intercept routes) gets the same regex denies, then the
    template rules, appended after its grants in its `unsafe_macos_seatbelt_rules` (emitted last, the last match wins). None of
    them needs an env file.
  - Authority: a line `secret files … in <roots>`, so a changed rule or root set replaces the process (Claude: next turn; Codex:
    next message, `plan.authority` in the worker scope).
  - Verified: unit tests (`ExternalSandboxTests`, `secretEnvFiles*`: folders, deny entries, rule order, regexes against nested,
    new and foreign paths, read-only project, Codex equals Claude), `nono profile validate` of the emitted document and `nono why`
    (`.env`, `.env.local`, `app/.env` denied for read and write, other files allowed) with the pinned helper. `nono why` does not
    read raw rules and reports templates as denied; it also evaluates only files that exist. The runtime probe
    (`scripts/probe-nono-runtime.py`, `developer/env-*`) has the Seatbelt checks (existing, new and nested files, link named like
    a template, mediated git, template read, write and create) but was not run: it needs a session outside any sandbox. Not
    checked live in a chat.
  - Cost: nono walks each root once per deny glob at every process start (no pruning, `walk_and_match`). Measured on this
    repository (about 180,000 entries with `.build`): 1.4-2.2 s for both globs in `nono run --dry-run`. A large shared root adds
    its own walk.
    an untracked, unignored `.env` makes `git add -A` fail. Tools that write `.env` (`vercel env pull` and the like) fail. Hard
    links to an env file made inside the boundary are not checked. Claude's Read tool under the boundary uses exact template
    exceptions via ordered relative gitignore negations in the same deny list
    ([Claude permissions reference](https://code.claude.com/docs/en/permissions#special-characters-and--negation)).
    The external boundary still checks file access. Fallbacks: the Claude CLI sandbox merges `Read` deny rules into its
    `denyRead` (code.claude.com/docs/en/sandboxing:
    a wildcard deny holds inside a wider allow), so Bash there is closed for `.env` and `.env.*`, templates included; not
    checked live. The Codex native path (`sandboxPolicy` `workspaceWrite`/`readOnly`) reads the whole disk and cannot deny a
    file inside a root, so Codex chats on the native sandbox can still read env files. Codex 0.171's permission profiles
    (`default_permissions`, `[permissions.<name>.filesystem]` with `":workspace_roots"` globs set to `"deny"`) could express it.
    The 0.171 app-server's experimental `permissions` fields are mutually exclusive with `sandbox` on thread start/resume and
    with `sandboxPolicy` on turn start. The native path sets those legacy fields explicitly. Protecting env files there requires
    migrating the native path's role-derived profiles across thread creation, resumption and turns, and verifying protocol
    compatibility across supported versions. That migration remains pending.

- Mediated `security` (2026-11-12): before, apple-signing mediated `/usr/bin/security` with Keychain read and no
  argument filter, so agents of such a project could read the whole login Keychain. It now carries an argument
  allow-list (`ExternalSandboxCommand.arguments` -> nono `from.session.invocation_policy`, default deny):
  `find-identity …` only. A signing project that calls other forms (`cms -D`, `find-certificate`,
  `unlock-keychain`) fails under the boundary with nono's fixed refusal. The shape was checked with the pinned
  helper (`nono profile validate`, `nono why`); the probes were updated but not run since.
- Named Keychain items (2026-11-12, `KeychainItemRule`): the planner mediates `security` when signing is on or the
  project lists items, one command with the rules unioned (`find-identity` prefix, exact `find-generic-password -s S
  [-a A] -w` orders per item). The list is part of the profile, so a changed list replaces the provider process at
  the next turn (Claude: plan authority in the launch identity; Codex: the worker scope) and an unchanged list keeps
  it. Proposal fields `addKeychainItems`, `removeKeychainItems` (at most 8 per change, 16 per project; names 1-128
  characters, letters, digits, inner spaces and `. _ - @ : / + =`, no leading `-`); the card shows the exact service
  and account with warning weight; settings section "Keychain items" in the sandbox pane. Paths: Developer under the
  boundary (both providers) reads listed items through the shim; every other `security` form is refused by nono. Not
  enforced on the Claude CLI-sandbox fallback or the Codex native sandbox (items work only under the boundary); Reader
  and Editor never; Routine operator (audit mode) and Operator unrestricted as before. An item without an account
  matches calls without `-a` only. The script must call `security` by name (`/usr/bin/security` exits 127 under
  nono). Claude's role hook (2026-11-21, `KeychainItemRule.isItemRead`, used by `ClaudeLaunchPolicy.inspection`): the
  Developer deny entry `security ` refused even these exact reads before nono saw them, while Codex (no hook) ran them
  (seen live in isostudio, item `isostudio-sentry`/`auth-token`). Now, only when the process runs under the boundary and
  the profile lists usable items, a command head that is exactly `security` (by name, unquoted) plus one of the item's
  `argumentForms`, followed only by harmless redirections (`2>/dev/null`, a temporary file), passes that one deny entry,
  also inside `$(...)`, after `VAR=` and in a pipe. Channel 2 (mediated command); nono's argument allow-list remains the
  enforcement, the hook only stops refusing what nono admits. Every other `security` form, other deny entries in the same
  line, the CLI-sandbox fallback and a profile without items keep the `denyList` refusal. The channel 1 hook now matches
  command basenames after removing quoting and recognized wrappers, including for multiword entries. This affects restriction
  matching only. Keychain and safe-removal exemptions still use the original command spelling. The OS boundary and broker
  enforce their own policies. Checked live 2026-11-13 (psy-wiki, Claude chat 1D20A230, build 502): the script's read failed, the agent
  wrote one proposal with `addKeychainItems` (service and account), the user applied it on the card, the chat
  continued by itself and the script read the key through the shim and completed the Deepgram transcription, with no
  macOS dialog reported; signing still finds the Apple Development identity with `security` narrowed to
  `find-identity`. Without any listed item and without signing `security` is not mediated, so the first failure is
  the plain Keychain error, not a nono refusal. Not checked live: nono's refusal text for an unlisted item once
  `security` is mediated, `dump-keychain` and other refused forms (run `scripts/probe-nono-runtime.py` outside any
  sandbox), Codex, an item created by an app whose ACL excludes `security`, and the mobile card (its proposal lines
  live in another branch).
- Claude file tools (Read, Write, Edit) reach a file directly inside the chat's own proposal folder without a prompt,
  under the boundary (ledger `boundary`) and on the CLI-sandbox fallback (`sandboxed`); the folder is the one the app
  chose from the session ID and real paths are compared, so another chat's folder, the inbox root, a subfolder or a link
  out keep the old answer, and under the boundary their refusal names `$SWITCHBOARD_SETTINGS_PROPOSALS` instead of
  `addFolders` (2026-11-13, unit-tested, not checked live). Codex needs nothing: under the boundary its edits are not
  asked (`externalSandbox`, `approvalPolicy: never`) and nono holds the granted folder.
- Mediated `git` and `gh` narrowed (2026-11-13, user decision; `ExternalSandboxPlanner.gitCommand`, `ghCommand`). Before,
  mediated git had Keychain read, network, every `GIT_*` from the caller and no argument filter, so an agent could read
  internet passwords (`git credential fill`), run shell code with the Keychain (`git -c alias.x='!…'`) and inject config
  (`GIT_CONFIG_COUNT`). Now:
  - git's own sandbox has neither Keychain nor network (`GIT_ALLOW_PROTOCOL=file`). Only `push`, `fetch`, `ls-remote` as the
    first argument, or after `-C <root>` where the root is the project or one of its folders (the queue's
    `git -C <repo> push --force-with-lease=…` and `ls-remote --refs`), run in a nono intercept sandbox with Keychain read and
    network: `GIT_ALLOW_PROTOCOL=https`, editors `:`, the caller's `GIT_*` dropped, and nono prepends `--no-pager -c
    core.hooksPath=/dev/null -c core.fsmonitor=false -c core.askPass= -c core.alternateRefsCommand=exit 0 -c
    credential.helper= -c credential.https://github.com.helper=osxkeychain -c gpg.format=openpgp -c gpg.program=gpg`. Any other shape (`-c`,
    `--config-env`, `--git-dir`, `--work-tree`, `--exec-path`, `--no-pager`, an alias, another or relative `-C` path) runs
    in the local sandbox, so its network fails with `transport 'https' not allowed`. `clone` gets network without the
    Keychain (its own `--config` can install filters): a private clone is `git init`, `git remote add`, `git fetch`,
    `git checkout`. `pull` (merge drivers and filters from the repository config would run with the Keychain) and
    `credential` are refused by nono with a text that names the route (`git fetch`, then `git merge --ff-only` or
    `git rebase`).
  - Environment: the local sandbox passes `PATH HOME USER LOGNAME LANG LC_* TERM TMPDIR SSL_CERT_FILE` and
    `GIT_AUTHOR_*`, `GIT_COMMITTER_*` (name, email, date), `GIT_INDEX_FILE`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_EDITOR`,
    `GIT_SEQUENCE_EDITOR`, `GIT_MERGE_AUTOEDIT`, `GIT_OPTIONAL_LOCKS`; the Keychain sandbox only the plain list. Never
    passed: `GIT_CONFIG_*`, `GIT_SSH*`, `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_PROXY_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`,
    `GIT_EXEC_PATH`, `GIT_TEMPLATE_DIR`, `XDG_CONFIG_HOME`. Both force `GIT_TERMINAL_PROMPT=0` and `HOME` (the real home),
    so the user's `~/.gitconfig` (identity, LFS filters, `http.postbuffer`) and Homebrew's system config (the
    `osxkeychain` helper) stay effective and cannot be replaced; `GIT_CONFIG_GLOBAL`/`NOSYSTEM` are not set.
    `GIT_EDITOR=true` and `false` now run in the local sandbox (exec of those two files allowed); `:` works everywhere.
  - gh: Keychain and network as before, argument allow-list (default deny): `pr`, `issue`, `repo`, `api`, `run`,
    `workflow`, `release`, `search`, `label`, `status`, `cache`, help and version, exact `auth status` (`--active`,
    `--hostname github.com`); refused with a reason: `auth token`, `--show-token`, `auth git-credential`, `extension`,
    `ext`, `alias`, `config set`; extensions and aliases run by name fall to the default deny. No `GH_*`/`GIT_*` from the
    caller (`GH_HOST`, `GH_CONFIG_DIR`, `GH_TOKEN`, `GH_ENTERPRISE_TOKEN` would redirect host, config or token); forced
    `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_PAGER=cat`, `HOME`.
  - Both providers (same planner input). Plan authority carries the sandboxes, routes, refusal forms and prepended
    arguments, so a change replaces the process (Claude: launch identity; Codex: next worker).
  - Rollback: `defaults write local.daniil.switchboard ExternalBoundaryGitNarrowingOff -bool YES` gives git and gh the
    previous policy from the next planned process of a chat (Claude: next turn, the authority changes; Codex: the next
    new worker). Delete the key to return.
  - Verified: the emitted document with the pinned helper (`nono profile validate`, unit test
    `narrowedGitPolicyIsAcceptedByThePinnedHelper` when `.build/nono/nono` exists): Keychain only in the intercepts;
    `nono why` for the refusals and, with each route's matchers replayed as an allow-list (`why` does not report
    intercepts), for the accepted and refused shapes. Not verified live: that an intercept sandbox really replaces the
    selection at run time and that `argv_prepend` reaches git, a real push with the neutral environment, LFS. The probes
    (`probe-nono-runtime.py`, `probe-codex-nono.py`) have the checks but were not run.
  - Remains: inside the Keychain sandbox `/bin/sh` must run (git runs every credential helper through the shell), so
    anything the prepended config does not cover could still run there; known uncovered: none for `push`/`fetch`/
    `ls-remote` over https. The remote URL, `url.*.insteadOf`, `http.*.proxy` and `http.*.sslVerify` are
    repository-controlled (URL-scoped `http.*` keys beat a command-line value). Host pinning (2026-11-13, user decision;
    `ExternalSandboxPlanner.gitCredentialHost`): the only helper is `credential.https://github.com.helper=osxkeychain`,
    so git asks it only when the credential's protocol and host are `https://github.com` (the final URL after
    `insteadOf`, and a proxy URL with a user name); no stored password of another site can be requested. The host is a
    constant, not read from `.git/config` (agent-writable) and not a project setting: a remote on another host gets no
    password under the boundary (`could not read Username`, prompts are off). Accepted residual (user decision
    2026-11-13: not needed, no follow-up task): with a local proxy and TLS verification off, or with verification on
    through the repository-settable `http.sslCAInfo`, `http.proxySSLCAInfo` or `http.curloptResolve`, an agent could
    still capture the `github.com` credential itself; closing it would need `network.allow_domain` on the intercept
    sandbox, which needs nono's session proxy for all agent traffic. Unit-tested; not checked live (probe check
    `developer/git-foreign-host-no-helper` exists, the probe runs only outside a sandbox). gh: `gh api`/`release upload` can upload any file gh reads, the Keychain database
    file included (encrypted); a proxy credential for gh is the later fix. LFS objects are not uploaded on push (the
    pre-push hook is off; `git-lfs` could not run in the mediated sandbox before either). `git -C <path>/ push`, a
    relative `-C`, `git remote update`, `git submodule update` and local `git fetch ../repo` (file transport) have no
    network or fail.

- Pipes between two mediated commands hang (nono 0.81.0 defect, found 2026-11-21). A Claude chat's
  `git show HEAD:PERMISSIONS.md | awk … | git hash-object -w --stdin` hung for over 30 minutes with no output; the
  file form `git hash-object -w --path P FILE` returned at once.
  - Cause, proven: the shim sends its stdio to the supervisor (`tool-sandbox/protocol.rs` `recv_stdio_fds`), which
    receives them with `recvmsg(…, 0)` and never sets `FD_CLOEXEC` (`crates/nono/src/supervisor/socket.rs`
    `recv_fd_via_socket`; macOS has no `MSG_CMSG_CLOEXEC`). `platform/macos.rs` `launch_child` then forks every mediated
    child with `std::process::Command`, which closes nothing else. So every mediated child inherits the stdio of each
    other mediated call in flight. Reproduced with the pinned helper outside any sandbox: the real `git apply --check`
    of `git show :f | git apply --check` held fd 16, the write end of its own stdin pipe (`lsof`), and never saw EOF.
    `wc -c | wc -l` hangs the same way, so it is not git-specific. v0.82.0 has the same code. No policy field controls
    it. `resources.wall_time_seconds` would also kill long `fetch` and `push` runs.
  - What works: a mediated writer into a plain reader (`git show … | cat`), a plain writer into a mediated reader
    (`printf … | git …`, a heredoc into `git commit -F -`, `< file`), command substitution, files. Concurrent
    mediated calls are not serialized. What hangs: any mediated reader whose input comes, directly or through plain
    stages (`awk`), from a mediated writer in the same pipeline: `git diff | git apply`, `git show | git hash-object
    --stdin`, `git format-patch --stdout | git am`, and the same with `gh` or `security`. The real child is started in
    its own session and survives the chat's kill; `ps` cannot show it under the boundary.
  - Mitigation, channel 2, both providers (shared planner, only with the git narrowing on): the existing git
    invocation policy refuses the prefixes `hash-object --stdin` and `hash-object -w --stdin`, bare or after `-C <root>`,
    before git starts. The RU/EN text names the cause and the file route (`git hash-object -w --path <path> <file>`).
    This also refuses the working plain-writer form of those two prefixes. nono's argv matchers cannot see where stdin
    comes from, and `apply`, `am`, `commit -F -`, `update-index --index-info`, `cat-file --batch` stay allowed, because
    a heredoc or file feeds them correctly. They still hang when a mediated command feeds them. `--path P --stdin` is
    not matched. No grant, route, approval, ledger reason or decision changes.
  - Not done: a Claude hook refusal for pipelines that join two mediated commands (Codex has no hook, invariant 14),
    and an upstream report to nono. Verified: unit tests (`mediatedGitRefusesHashObjectStdinAndKeepsFileOperands`,
    `nono why` with the pinned helper), the probe `scripts/probe-nono-runtime.py --nono .build/nono/nono
    --git-stdin-only` outside any sandbox (refusal exit 126 with the text, file route, plain pipe returns, and
    `git/nono-mediated-pipe-leak-still-present`, which fails once a fixed helper stops the hang). Not checked live in a chat.

- `scripts/build-app.sh` and the queue's `confirm-live` read the process list and a process's path and
  start time through libproc instead of `ps` (2026-11-12): `ps` stopped the app build after a
  successful compile under the boundary. libproc sees every process there.
- Mediated `git` (2026-11-12): `/usr/bin/git` is Apple's `xcrun` shim and cannot start inside a
  mediated sandbox (`couldn't stat Xcode's Info.plist`; seen live in this project, where every git
  command failed under the boundary). The planner now mediates the real binary (`resolveGit`:
  Homebrew's git, else `xcrun --find git`). Checked live with Homebrew's git; the `xcrun` branch
  is covered by a unit test only.
- A checkout behind `origin/main` still has the old `scripts/verify-project.py` and
  `scripts/build-app.sh`: from a chat under the boundary they fail on `ps` until the checkout is
  updated (run the queue script of an updated worktree with `--repo` and `--state-dir`).
- The queue holds an install lease: while an installed batch still waits for `confirm-live` or
  `publish`, `install` of another batch is refused, unless the lease is older than 45 minutes or
  the user approves `install BATCH --take-over` (see `scripts/verification-README.md`).
- Mediated `git` cannot exec helpers outside its trees (`/bin`, git-core, and since 2026-11-13 `/usr/bin/true` and
  `/usr/bin/false` in its local sandbox): `GIT_SEQUENCE_EDITOR=sed …` fails; `GIT_EDITOR=:` (git's built-in no-op) and
  `true` work. With the rollback switch on, `true` fails again.
- Process-fixture tests (`ClaudeInteractiveTests`) were flaky when run from a chat under the external boundary
  (2026-11-13, queue logs `1297d1b3`, `f948a195`, `c24b35de`). The earlier note blamed the SwiftUI layout suite
  `SettingsProposalLayoutTests` for doubling their wall time; that was wrong: the same suites take 8-9 s with or
  without it under the boundary and about 4.3 s outside any sandbox, so the slowdown comes from the boundary
  (process start and file I/O; its cause is not investigated). The failures had two separate causes:
  - Read races, seen with and without the layout suite: `claudeDeveloperWritesIntoASharedFolderWithoutAsking`
    decoded `home/answer` once the file existed, while the fixture was still writing it. Fixed in the tests: the
    fixtures replace whole-document files through a temporary file and `os.replace`, append log lines with one
    `os.write` on an `O_APPEND` descriptor, record a launch before their first frame, and the test waits until the
    answer decodes. Every other fixture file a test reads is written before the frame the test waits for. With
    `SWITCHBOARD_FIXTURE_DELAY_MS` (tests only: each fixture write and frame waits that long) the four process-fixture
    suites pass at 150 ms and 250 ms (about 2x and 2.7x their wall time); the old read fails every time at 150 ms.
  - Extra launches (`claudeDeveloperRoleRegistersTheCommandHookAndAnswersByRole`,
    `claudeBoundaryHandsTheTokenOnlyOnFd3AndAnswersByTheBoundary`, and locally `claudeIdleBackgroundCliIsReleased`),
    seen only in runs that included `SettingsProposalLayoutTests`. Not slowness: that suite switched the process-wide
    app language (`L10n.use`) while it rendered, the Claude system prompt is localized and part of the launch identity,
    so a turn submitted in that window replaced the warm process. The app itself never switches language in a running
    Mac process, so this was a test interference, not a product race. Fixed in the tests: `SettingsProposalBoundarySummary`
    takes an optional `language` (default: the process language) and the layout suite renders both languages through
    it; `noTestSwitchesTheProcessLanguage` fails when a test file calls `L10n.use(` again (allowed list empty).
    `ClaudeInteractiveTests` with the layout suite then passed 7 of 7 local runs. A separate `native-tests` check
    would not have isolated the suites anyway: the verification queue merges all `native-tests` filters of one task
    into a single run. The two exact-count assertions print the launches (the boundary one with each prompt's start).
- A task submitted from the CLI sandbox cannot be run from a chat under the boundary (`toolchain changed since
  submission`): the environment fingerprint differs. Submit and run from the same mode.
- Narrowed git and gh, live 2026-11-13 (Claude chat 4942F27A, build 508): local git keeps the user's identity
  (author name and email equal the global config), `GIT_EDITOR=true` and `:` work, an alias gets no Keychain, `GIT_CONFIG_COUNT`
  injection is ignored; `fetch`, `-C <project> ls-remote --refs` and `push --dry-run` work; `pull` and `credential` are
  refused with the route text; `-c ... push` is routed to the local sandbox (`transport 'https' not allowed`); the queue
  published this change itself (push with a lease) under the narrowed git. Not checked live: Codex, `clone`, the probes,
  the rollback switch.
- `gh` under the boundary (fixed 2026-11-13, user decision; `ExternalSandboxPlanner.ghLoginReads`, `chainGitHub`). Before,
  repository commands failed: `gh pr checks` started git and nono refused the chain (`tool 'gh' is not allowed to invoke
  git`), and gh found no login: `~/.config/gh` was not readable in its sandbox, and its keyring lookup (go-keyring starts
  `/usr/bin/security find-generic-password -s gh:github.com` by absolute path) is refused in every project, because
  nono's child exec gate (`add_child_process_exec_gate_with_policy`, `tool-sandbox/platform/macos.rs`) lets gh's sandbox
  start only gh itself and the shims; seen as HTTP 401 with the account read. Seen live in Codex chats 2849861C (hw-bench,
  git chain) and 92CF9E1E (nextjs-sanity-platform: no `github` access set, so gh ran unmediated without its login; the
  route there is a proposal with `addPresets: ["github"]`). Now:
  - The `github` access set no longer lists `~/.config/gh` as a session read (it did until 2026-11-13, so every command
    of such a project, `cat` included, could read gh's login record against invariant 12; on the native paths gh runs
    as a trusted command outside the sandbox and never needed it).
  - gh's sandbox alone reads `~/.config/gh`, read-only, when `hosts.yml` has no plain-text `oauth_token` value; with a
    plain token (`--insecure-storage`) nothing is granted, because `gh api` can upload any file gh reads. A linked folder is
    not followed. Part of the authority (`reads=`), so a change replaces the process.
  - In the narrowed mode only: gh `can_use` git; git's `from.gh` edge is a copy of its session edge (local sandbox, the same refusals; the intercepts
    give push/fetch/ls-remote the same Keychain route as the agent's own call). A chained call never gains a right the
    agent's direct call lacks.
  - gh's sandbox may start `/usr/bin/security` (one Seatbelt `process-exec` rule through `executableFiles`, emitted in
    `unsafe_macos_seatbelt_rules`, which lifts the child exec gate for that file only). An intermediate attempt
    (`allow_direct_exec_bypass` on `security`, 2026-11-13) did not help and was removed: that field only affects the
    session's outer exec gate (`add_outer_process_exec_gate`), not a command sandbox's children; the earlier note that a
    start by absolute path runs in the caller's sandbox was wrong.
  - Residual risk: gh's sandbox holds Keychain read and may now run `security` with any arguments. gh itself starts it
    only for its own item, and the agent cannot make gh run another program (extensions and aliases refused, no `GH_*`
    passed), but any code path that runs inside gh's sandbox could read other Keychain items. Before the narrowing gh had
    the same Keychain grant; a proxy credential would remove it but needs nono's CA in the user trust store for Go
    (`macos_trust.rs`; user decision 2026-11-13: not now).
  - Verified: unit tests and `nono profile validate`/`nono why --caller gh` with the pinned helper. Live: see
    `docs/improvements.md`. `gh auth token` and `gh extension` stay refused; `gh -R owner/repo …` with `-R` first stays
    denied by the argument allow-list (put `-R` after the subcommand).
- Settings proposal files in a chat's own folder that do not decode or change nothing are still removed, but the app
  now queues one fixed continuation to that chat (`SettingsProposalOutcome.unusable`, RU/EN, with the format, at most one
  per chat in ten minutes). Before (until 2026-11-13) they vanished unseen and the chat believed its request waited.
- Codex commands bypassed the mediation shims (found live 2026-11-13, Codex chat D12755A8, arena-hw-bench, build 508).
  Codex 0.167.0 runs shell commands as `zsh -lc` (codex-rs/core/src/shell.rs `derive_exec_args`, login on by default),
  and its shell snapshot is also taken in a login shell and applied only to `-lc` commands
  (core/src/tools/runtimes/mod.rs `maybe_wrap_shell_lc_with_snapshot`). A login zsh reads `/etc/zprofile`, whose
  `path_helper -s` puts the `/etc/paths` folders first, so `/usr/bin/git` came before nono's shim folder and mediated
  `git`, `gh`, `pgrep`, `security` ran unmediated, without the Keychain (private https fetch failed). Claude chats under
  the boundary showed the shim folder first (nono prepends it to the PATH it passes on). Fix
  (`CodexConnection.boundaryArguments`, `boundaryEnvironment`): under the boundary the app-server gets
  `-c allow_login_shell=false` (core/config.schema.json: login requests are rejected and an omitted `login` means a
  non-login shell; the snapshot warm-up is skipped, core/src/unified_exec/shell_snapshot.rs), so commands run as
  `zsh -c` with the PATH nono passed on, shims first. The provider's PATH under the boundary is Claude's base list
  (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`) followed by the app's other inherited absolute
  entries, once each. PATH is lookup order only; no right changes. Side effect: Codex commands under the boundary no
  longer read the user's login profile, so PATH additions from `.zprofile` and `.zshrc` are absent (`.zshenv` is still
  read). The native path is unchanged. A worker started before the update keeps the old arguments until it is replaced.
  Checked live 2026-11-13 (same Codex chat D12755A8, build 513): `which -a git` prints the nono `shims/git` first,
  `git ls-remote --heads origin` on the private https repository returns 2 heads, mediated `pgrep -lf Switchboard` sees
  processes outside the sandbox. Not checked live: `gh` and `security` in Codex, Keychain items in Codex, Homebrew tools
  on the new base PATH.
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
- The command inventory (`ExternalSandboxPlanner.unrunnableTrustedCommand`) and mediated `pgrep` apply
  to both providers through the same planner inputs (Codex since 2026-11-12, after the user removed
  this project's trusted `/usr/bin/log show`). The base entries `ps` and `sysctl -n` are exempt for
  both. Not checked live for Codex: a project with an unrunnable trusted command and its notice
  (`pgrep` is checked).
- The Codex fallback notice appears when a worker starts (new chat, scope change), not on every
  turn: a chat whose worker is kept shows it once. Claude shows a notice for "command sandbox off";
  Codex treats it as role-defined and only logs it, as the brief of 2026-11-12 asked.
- Claude's own Claude in Chrome bridge (`--chrome`) is not verified under nono. Since 2026-11-13 a
  Claude chat with the My Chrome add-on runs under the boundary with the app-owned
  `switchboard_user_chrome` server behind the relay (channel 3, the server Codex uses; no `--chrome`),
  when the app issued the chat a grant (Switchboard extension installed, paired, enabled). Without a
  grant it stays on the CLI sandbox with `--chrome` and the notice names the pairing. Claude chats
  outside the boundary (Operator, any fallback) keep `--chrome`, so the two paths have different tool
  sets. A grant's capability rotates after an hour without a send; the changed launch then replaces
  the process at the next turn, also one kept for background tasks. The settings proposal review
  treats "extension installed" as "grant available" (`UserChromeControl.isInstalled`). Not checked
  live yet: see section 5.
- Access requests: eligible cards reach the mobile app (pending live verification); all target
  projects must be shared. A proposal without a known author (a root
  file without a valid `chat`, a folder of no current chat: unknown, archived, a scheduled run, an
  unmapped Codex token) keeps the global sheet, says so, and continues nothing. A running turn is
  not interrupted: the new rights apply from the next turn.
- Per-chat proposal folders (2026-11-12): the author comes from the folder the app chose at launch,
  never from the agent (defect: Codex chat 65037D41 wrote no `chat`, so Apply continued nothing).
  An existing chat gets its folder at its next process launch (Claude: the grant is part of the
  launch identity, so the first turn after the update replaces the process once; Codex: the next
  new worker). Until then a process started before the change still holds the whole inbox and
  could write into another chat's folder. Review ids are `<name>.json` or `<folder>/<name>.json`;
  `remove` refuses `..`, deeper paths, hidden names and linked folders. Empty folders of no chat
  are removed after an hour. A Codex token folder whose map entry is lost (the map write failed)
  is treated as unknown. Not checked live.
- Refusal texts without the route: Claude `outsideRoots` on the CLI-sandbox path, `network` (role
  without network, in `permission()` and the hook), `connectorScope`, `turnEnded`,
  `unsupportedTool`, `notOwnSubagent`. Codex: the app answers approvals with protocol decisions
  (`decline`, `cancel`) that carry no text, and an engine refusal under `approvalPolicy: never`
  has no app text. A nono OS refusal carries no text for either provider. These paths are covered
  only by the `AgentAutonomy` rule. ACP (Gemini) refusals are unchanged.
- `addCommands` under the boundary (2026-11-12, defect: psy-wiki Claude chat 9D550E53 applied a trusted
  `scripts/transcribe-audio` that reads the Keychain; nothing changed and the chat retried). The review (card and
  sheet) now plans the requesting chat's provider and role (unknown author: every provider, project default role) for
  the project as it would be after the proposal, with the adapters' planner inputs (`SettingsProposalBoundary`,
  `AgentIntegrationFactory.proposalBoundaryKind`). Per added command it says either "runs inside, no extra access"
  (naming an access set whose mediated command would cover it; else an app-owned tool, a folder, a Keychain item; for a
  `security` command always a Keychain item, `addKeychainItems`) or "the boundary cannot run it: the chats move to the
  provider's sandbox with prompts". Apply stays enabled.
  When everything the proposal adds is such a no-effect command, the continuation is the fixed `appliedWithoutEffect`
  text (do not retry; report the blocker or request the right access). Not checked live; the Claude token and Codex
  launch-info preconditions are not part of the review.
- Project skills (2026-11-12, `ProjectSkills`): the app's link folder `project-skills/<project key>` in its data
  directory (outside every provider home and project) is a read grant for both providers: Claude through
  `sandboxReads` (CLI sandbox and the boundary's `extraReads`), Codex through the worker's `workflowDirectories`.
  Each link points at a skill folder inside the project, which the chat already reads; skills whose folder,
  `SKILL.md` or any inner link resolve outside the project, or whose front matter has keys beyond
  `ProjectSkills.descriptiveKeys` (`allowed-tools`, `hooks`, `model`, ...), are not linked. The user's own
  `~/.claude/skills` have no such front matter filter. Checked live 2026-11-13: Claude lists and launches
  `project:<name>` (psy-wiki `.claude/skills`, this project's `.agents/skills`), Codex lists the same skills by bare
  name, no duplicates. Not checked live: a skill excluded for its front matter, a link out of the project.
- Grants carry no origin: the settings do not record when, by which chat and why a folder or command
  was added, and nothing reports a grant that is never used.
- Roles without network stay on the native path (the proxy allowlist for model hosts is not wired).
- `git worktree add ../sibling` is outside the git grant.
- Requests outside an active turn (background sub-agents) get the role's own answer; what would
  need the user is refused.

### Native push signing key (2026-11-13)

`Switchboard.APNs` is a reserved Keychain service prefix for both providers. Project
settings cannot grant its items to agents. The Mac app reads/writes the signing key
itself through Security.framework (`Switchboard.APNs.v1`, account `auth-key`); agents
never receive the PEM or JWT. No new role, broker grant or app-owned agent tool is added.
This uses ordinary application storage, not a new agent permission channel. Source
and tests run inside the existing boundary (channel 1). The fixed app-owned iPhone
installer (channel 3) keeps its existing signature/team/bundle checks and no-retry rule.
No permission invariant or taken decision changes. PostgreSQL database tests remain
blocked inside the external boundary by its shared-memory refusal (the user ran the suite successfully in Terminal); a trusted Python command
would not remove that boundary and is not a valid workaround.

### Docker daemon socket (2026-11-20, live check pending)

Found: a chat of `sportradar-engineering-exercise` got `~/.docker` as a writable folder, yet
`docker version` still failed with "permission denied" on `/var/run/docker.sock` (a link to
`~/.docker/run/docker.sock`). nono 0.81.0 has the required group `deny_credentials` (`~/.docker`,
`~/.ssh`, `~/.aws`, `~/.kube`, `~/.npmrc`, ...); `--allow` does not lift it, only
`--bypass-protection <path>` does (`nono run -v --dry-run`).

User decision: a `docker` access set, ticked on purpose (no markers). Channel 1 (inside the
boundary), compiled from the project settings (invariant 1). `AccessPreset.unixSockets` reaches
`CommandSandbox.unixSockets`; the planner resolves each existing socket (the link target) and passes
`--allow-unix-socket <socket>`, plus `--bypass-protection <socket>` when the socket lies under a
`protectedPaths` entry. Claude's native sandbox gets `network.allowUnixSockets` and a read grant of the
socket file (both the given path and its target). Under the boundary `DOCKER_CONFIG` points to an empty
folder in the worker's temp grant: Testcontainers (`auth/get-auth-config.ts`) sees `~/.docker/config.json`
and fails with EPERM reading it; registry sign-ins therefore stay unavailable to agents. Known gap: Claude's
native sandbox does not set `DOCKER_CONFIG`. Codex native `workspaceWrite` with network already
allowed the socket; no change there. Risk accepted by the user: the daemon can start a container that
mounts any shared host folder, so this set reaches beyond the project roots.

Diagnostics: a saved folder grant under `protectedPaths` is reported in the chat on launch by both
providers (`ExternalSandboxPlan.protectedFolders`, `foldersNotice()`), and the agents' proposal rule
says such folders stay closed and names the `docker` set. `protectedHomePaths` copies nono 0.81.0's
`deny_credentials` and `deny_keychains_macos`; update it when nono is upgraded.

### Missing explicit folders (2026-11-15, implementation pending verification)

Channel 1 fixes compilation of existing grants, without changing an invariant or taken decision.
A saved explicit folder that does not exist remains omitted from nono, never replaced by its
parent and never created by the planner. Both providers diagnose these exact omitted roots in
the chat on launch. These diagnostics are UI events, not model context. Optional absent preset
paths stay quiet. Existing proposal review (Mac and phone) warns before Apply, and its fixed
continuation distinguishes saved access from effective access. Duplicate proposals keep the
existing `alreadyGranted` outcome; shared RU/EN instructions explain the distinction and forbid
repeated proposals, parent grants as a workaround and uncertain action replay.

Codex now recomputes the existing plan at each prepare/submit and includes `plan.authority`
in its existing dedicated-worker scope. Claude already compares that authority each turn.
A filesystem change that changes compiled grants replaces the worker on the next message,
including its background descendants; it does not hot-patch a running process or retry a turn.
Codex keeps a new thread's original token inbox while comparing plans, so the first subsequent
message alone does not change authority. Replacement releases the old thread writer, stops the
old worker tree before resuming the new worker, and clears a failed replacement's scope.
No filesystem watcher, new policy layer, app-owned tool, fallback or additional grant is added.
Live checks and required sandbox probes remain pending; see `docs/improvements.md`.

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

Keychain items are listed per project in every review: each is a standing secret grant. An item no
script reads any more is removed.

Removals go out as settings proposals (`removePresets`, `removeFolders`, `removeCommands`,
`removeKeychainItems`), one rule
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
| Named Keychain items: validation, reserved list, argument forms, card lines | `Sources/ContextCore/KeychainItems.swift` |
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
| Skills in chats (user and project) | `Sources/ContextCore/ProjectSkills.swift`, `Sources/ClaudeAdapter/ClaudeSkills.swift`, `CodexClient.swift` (`refreshProjectSkills`) |

Profile rename correction (2026-11-14): extension Save sends profileRenamed metadata over
the existing native connection (channel 3). Only that connection's profile name changes,
including its saved paired name; grants, pairing, sessions and tab leases stay unchanged.
No permission invariant or decision changes. Live verification is pending.

Chrome setup UX (2026-11-14): code-first discovery uses the existing app-owned
native coordinator (channel 3). resolve-pairing-code is authenticated with the
app's control token; it returns metadata only for a unique live unpaired profile.
Missing/duplicate codes fail closed; explicit Pair still revalidates the code.
Discovery and automatic status refresh never pair/select/grant. Saved profile
selection remains explicit and does not move existing chat grants. Clipboard copy
runs only on the user's popup click, with no new extension permission.
No role, boundary, grant invariant or taken decision changes. Live UI checks pending.


Attachment read parity (2026-11-14): channel 1 compiles the existing app-owned
attachment read policy in the shared external-boundary planner, for both providers.
Only `dropped-files` and `mobile-photos` are added read-only, never the app data root
or provider credentials. Claude's native Read/sandbox policy uses the same root list.
Stores are created before planning so an existing worker can read its first later
attachment; new/resumed workers receive the grants after the app update. Already
running old workers require replacement/restart. This preserves the existing Claude
store-wide attachment policy; per-chat attachment isolation is not introduced.
No role setting, access set, ledger reason, approval or taken decision changes.
Regression checks and live verification: see docs/improvements.md.

User Chrome extension tools (2026-11-14): channel 3, the existing `switchboard_user_chrome`
server and extension. New typed arguments only: `x,y` (pixels of the extension's own latest
screenshot of the leased tab, refused after a scroll, resize or navigation), click variants,
a closed key list with modifier chords, `set_value` (select option or checkbox state),
`waitSeconds` (at most 10) and a screenshot `clip`. No caller code, CDP command, selector or
path is accepted. The sensitive-field rule now also covers a point under a coordinate click,
the focused element for type and printable keys without a ref, and file inputs (use upload).
Reads report form values of non-sensitive controls only. Input by ref works in same-process
frames; out-of-process frames stay refused. Hover, drag and authenticated fetch were left out
(handoff defaults, not user decisions). Observation stays read-only (`readOnlyHint`), input
stays destructive. The extension reports a feature revision; the coordinator refuses newer
arguments for an old extension before journaling. No grant, lease, journal or boundary change.

Claude connector scopes (2026-11-15): the existing boundary launch preserves the
profile OAuth document's actual scopes in CLAUDE_CODE_OAUTH_SCOPES. The access token
still travels only through fd 3; no credential grant or role change. In installed
Claude Code 2.1.325, AV defaults fd credentials to inference/upload scopes and the
connector loader returns early without user:mcp_servers. Inherited scopes are
replaced, never unioned; absent metadata adds no connector scope. Codex is unaffected
because this is the Claude-specific credential transport. Live verification pending.

My Chrome tab ownership (2026-11-18): the app-owned coordinator and extension
enforce per-chat tab leases through channel 3. Selection of a tab already leased
to the requesting chat reuses its current lease under that chat's existing grant.
A lease held by another chat blocks selection and identifies its owner. Selecting
an unleased existing tab still requires explicit user selection. A single control
on the right side of each chat opens a list of that chat's managed tabs and their
activity. The user can release a single lease from this list or the
Chrome extension popup. The app uses the coordinator's private control token.
The extension verifies the popup sender and removes the exact lease before
notifying the coordinator over the paired native connection. Release preserves
the open Chrome page, the chat's My Chrome grant and other leases.
External actions still require the applicable authorization. Transport errors
with uncertain outcomes prohibit replay.

My Chrome visual indicators (2026-11-18): channel 3 uses the extension's existing
debugger access to draw a passive outline, a badge with a shadow below it, and a temporary agent pointer in the
leased HTTP(S) tab's top-level document. The extension supplies the fixed overlay
and draws the pointer from its own mouse dispatch coordinates. The overlay runs
in an isolated world, ignores page input and follows the tab lease lifecycle.
This uses the existing extension permissions and requires an active lease.
