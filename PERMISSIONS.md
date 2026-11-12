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
- Under the boundary an action outside the roots fails; it is not asked. The user accepted this for
  Developer chats.
- Sub-agents inherit the parent's rights. The role cap limits their tool names only; there is no
  read-only promise for them.
- A project whose trusted commands nono cannot mediate is ineligible for the boundary until those
  commands are removed, mediated or replaced by an app-owned tool.

## 5. Current state (2026-11-12)

| | Codex | Claude |
| --- | --- | --- |
| Enforcement for eligible Developer chats | External boundary (nono), since 2026-11-11, commit 2cddfce | CLI sandbox for Bash + the app's `can_use_tool` answers + command hook (phase A, commit fc6075a) |
| Prompts for commands | None: `externalSandbox`, `approvalPolicy: never` | None inside the CLI sandbox; a flagged command runs unasked only if `trusts` accepts it, else asks (attended) or is denied (unattended) |
| File tools | Share the session union (approximation: access-set paths are writable to them) | Answered by roots in `permission()` |
| Leaving the sandbox | Not possible; mediated commands and relay tools only | `dangerouslyDisableSandbox: true` + trusted command |
| App-owned tools | Through the relay | Direct MCP servers (no relay yet) |
| Ineligible cases | Operator role, role without network, command sandbox off, helper not verified: native sandbox with prompts | Same roles use the role's own rules |

Claude phase B (the same nono boundary) is not implemented. B1 probe: credentials option d
qualifies (token on fd 3 through a launcher; the worker is relaunched with a fresh token before
expiry); checks 2-5 pass; sub-agent teardown (check 6) is unverified. B2 (integration) is not
started. The plan and the brief are in `docs/handoffs/claude-boundary-2026-11-12/`.

Known gaps. Check this list before you treat a failure as a new defect.

- Under nono `ps` cannot run (setuid) and `log show` cannot run in any sandbox. `pgrep` sees only
  sandboxed processes unless mediated. `lsof -i` and `sysctl -n vm.loadavg` work.
- `scripts/verify-project.py` calls `ps` and `sysctl` itself, so the verification queue fails from a
  chat under the boundary (`Operation not permitted: 'ps'`, 2026-11-12). Intended fix, not built:
  the queue takes load and process facts from the app's diagnostics (channel 3); build and tests
  stay in channel 1.
- `scripts/request-app-restart.sh` starts a second app instance and needs `NSWorkspace`; under the
  boundary this is unverified. Intended fix, not built: a restart request as an app-owned tool.
  `AGENTS.md` still tells Codex to use `require_escalated`, which a chat under the boundary does not
  have.
- This project's trusted `/usr/bin/log show` needs an app-owned tool before Claude can move under
  the boundary.
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
5. **Verify** (section 7), then update section 5 if the state or a known gap changed.

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

## 7. Verification

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

## 8. Code map

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
| App-owned tools | `ChatDirectoryRuntime/server.py` (`inspect_chat`, `project_diagnostics`), `BrowserRuntime/`, `UserChromeRuntime/` |
| Settings proposals | `Sources/ContextCore/SettingsProposals.swift`, `Sources/ContextDesk/SettingsProposalView.swift` |
| Settings UI | `Sources/ContextDesk/ProjectSettingsView.swift`, `ProjectPermissionsView.swift`, `SharedRootsSettings.swift` |
| Ledger and review | `Sources/ContextCore/CapabilityLedger.swift`, `Sources/AgentContract/AgentRuntimeEvents.swift`, `.agents/skills/access-review/` |
| Agent-facing instructions | `Sources/ContextCore/AgentAutonomy.swift`, `sandboxCommandInstructions` in `ClaudeIntegration.swift` |
| Build under the boundary | `scripts/swift-task.py` (`SWITCHBOARD_EXTERNAL_SANDBOX`) |
