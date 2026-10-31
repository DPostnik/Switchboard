# Scheduled jobs

Switchboard owns a local scheduler under the user's authorization of 2026-09-27. Open **Scheduled jobs** to create a task, or select an external definition and import it. Definitions and run history live in `Application Support/Switchboard/scheduled-jobs.json`; original Codex and Claude schedules are never edited.

## Execution

- The app must remain open and the Mac awake. Closing the window keeps it running; Cmd+Q stops scheduling. There is no launchd job or second background service.
- The scheduler polls every 15 seconds, admits up to three tasks concurrently, and never overlaps runs of the same task. After downtime, each overdue task runs once; missed occurrences are collapsed. Interval schedules restart their interval from dispatch time. Daily/weekly schedules use the stored IANA time zone, including DST.
- Supported schedules: manual, one-time, `MINUTELY`/`HOURLY` with positive `INTERVAL`, and `DAILY`/`WEEKLY` with `BYHOUR`, `BYMINUTE`, optional zero `BYSECOND` and `BYDAY`. Multiple hours/minutes are supported. Daily/weekly intervals other than one, monthly rules, COUNT/UNTIL and other unimplemented fields are rejected rather than silently simplified.
- A manual run leaves the next scheduled occurrence intact. Enable/resume computes the next future occurrence; it does not replay the pause interval. Editing/deletion waits for the current run to stop.
- Every dispatch is recorded atomically before contacting an engine. An exclusive process lock prevents multiple app instances from dispatching the same ledger. Unknown versions/corrupt storage fail closed. Persistence failure stops scheduling.
- A run's outcome never pauses its recurring schedule: failed, stopped, permission-blocked and uncertain runs remain in history, and enabled tasks continue at their next scheduled occurrence. Recovery marks unfinished runs uncertain without changing the task's enabled state or next occurrence. The consumed occurrence is never automatically resent. Pausing a recurring task is an explicit user action; previously paused tasks stay paused. One-time schedules still end when their only occurrence is claimed.

## Engines and permissions

**Codex:** creates a fresh normal app chat per run, using the task's saved model, effort and route, and the project's current permissions. Existing chat selection and draft remain intact. Approval and user-input requests use the normal chat UI. History links to the resulting chat; deleting that chat removes access to its transcript, not the task's run metadata. The app's dedicated Codex home remains authoritative; external threads, credentials and settings are not imported.

**Claude Code:** uses the installed CLI, pinned to the verified `2.1.292` print JSON protocol. It uses existing Claude authentication and project/user permission rules in place; it does not copy credentials. `dontAsk` and `--permission-prompts none` deny actions requiring new approvals. There is no bypass/auto-approval flag. Permission denials are reported as blocked without changing the schedule. Each run that reaches dispatch also appears as a chat in the task's project sidebar, titled with the task name and linked from the run history ("Open chat"). This chat is a read-only local record of the run (prompt, final result, timing and a non-completed status), not a resumable Claude session (`--no-session-persistence` is kept): opening it never contacts an engine or dispatches anything, the composer and context handoff/summaries are disabled, and Stop in the chat stops the job. Archiving or deleting the record does not change the run history. The runner passes prompts through stdin without a shell, limits each run to one hour and 8 MiB of output, and supports stopping. Stopping after dispatch leaves an uncertain outcome because terminating the CLI cannot confirm all side effects. When the Switchboard browser is enabled and installed, each Claude run gets the same browser MCP server as Codex chats (`--mcp-config` with a fresh per-run profile lease, `--allowedTools mcp__switchboard_browser`; other MCP configuration is not disabled), plus the task's standing Chrome session import permission if set. After the run, its dedicated Chrome is closed with one request and the profile is released; an unconfirmed close keeps ownership, adds a note to the output and is not retried. A task with session import is blocked before dispatch when the browser is disabled or missing. Full Claude interactive conversation support is separate work.

Claude tasks require a full-access project **and** explicit per-task consent to external Claude policy in the editor. Standard project restrictions are rejected before dispatch, even if consent is checked. Existing/imported tasks receive no automatic consent. The CLI controls account and routing; it is not a verified direct or app-optimizer route. App optimizer routes are rejected. A reasoning-effort override is forwarded to the CLI when it names a documented level (low, medium, high, xhigh, max); any other nonempty value is rejected before dispatch. The editor exposes these capability limits in Russian and English.

Both engines now run through the typed `AgentScheduledExecutor` contract. The separate `ClaudeAdapter` target owns the native print runner; Codex retains app chat bookkeeping and uses `AgentIntegration` for execution. No engine fallback or automatic retry is introduced.

## Import

- Codex: reads `~/.codex/automations/*/automation.toml`, including prompt, RRULE, model, effort and candidate project paths. Unsupported schedules must be edited explicitly. An external target thread's history and worktree configuration cannot be carried into the app's dedicated home.
- Claude: reads the Markdown body of `~/.claude/scheduled-tasks/*/SKILL.md`. The documented file has no schedule, folder or model; the editor requires selecting a project and reviewing these fields. Until a schedule is selected, it is manual-only. The directory name supplies the display name; YAML is not executed or treated as scheduling policy.
- Imports are paused by default and never enable the external scheduler. Enabling an imported schedule requires the user to confirm they disabled its original schedule in the source app. This confirmation prevents an accidental double schedule; Switchboard cannot verify remote/cloud scheduler state. A manual run is always an explicit action.

Source contracts: [Claude Desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks), [CLI reference](https://code.claude.com/docs/en/cli-reference), [permission modes](https://code.claude.com/docs/en/permissions). Checked 2026-09-27 against the installed CLI version and help. Real user jobs were not executed as part of development validation.

## Chat control — 2026-09-27

The bundled [schedule-control skill](Skills/schedule-control/SKILL.md) lets an
authorized agent list app-owned jobs, import recurring Codex definitions, edit
instructions, enable or pause jobs without Apple Events. Its Python client sends private, expiring
JSON requests to the running scheduler; it never edits the ledger directly.
The app preserves project/model/route/permission settings and uses its existing
JobStore and routine validation. Enabling a Codex import independently verifies
that its exact original is PAUSED, with explicit source-disabled confirmation.
Other imported engines require the editor's existing confirmation flow.

Updates compare the full observed job to reject concurrent edits; active runs
cannot be edited. Requests are claimed before execution and never replayed.
Unknown operations, versions, fields, expired requests, nonprivate files and
symlinks fail closed. A failed persistence acknowledgement is uncertain, not
permission to retry. Use `status REQUEST_ID` and inspect current job state.
Receipts stay in the private home with no automatic retention policy yet.

The scheduler polls every 15 seconds. The client waits up to 40 seconds per
request, with a 60-second expiry. The app must be open and the Mac awake. New
builds need Cmd+Q and reopen before their control channel is available. This
feature does not add immediate execution, deletion or external scheduler
management. Recurring Codex imports are supported as described below; other
creation and schedule changes use the editor.


## Recurring imports from chats — 2026-09-27

The control client now supports `catalog` (source definitions with digests and
existing project IDs) and `import --source-id ID --project-id UUID --time-zone ZONE
--model MODEL --effort EFFORT --recurring [--prompt-file FILE]`. Imports always
start disabled. The running owner validates the selected source digest, source
identity, known format, exact recurring rule, existing project, explicit inherited
model/effort, and unique source before saving. It never imports source sessions or
credentials. A successful import reply is not a run result.

The user's standing authorization permits agents to choose ongoing routines,
pause originals through an available supported source tool and enable verified
copies without another per-task confirmation. The source-disabled flag records
verified state. Finite pilots and one-time tasks remain excluded. The new channel
rejects unsupported expiry rules rather than removing them.

The source app's `automation_update` tool is a separate capability; this app does
not provide or emulate it. If it is not available, stop with the copy disabled.
Never replace it with direct edits of external definitions or guessed IPC. When
available, verify both source pause and absence of an active/uncertain source run,
then enable and inspect the destination response. No automatic pause retry or
source resume/rollback follows an uncertain result. Current Switchboard import
support is implemented independently of that external capability limitation.

## Creating tasks from chats — 2026-10-19

The control client now supports `create --name NAME --project-id UUID --prompt-file FILE
--rule RRULE --time-zone ZONE --model MODEL --effort EFFORT [--engine codex|claude]
[--enable]`. An agent chooses only those fields. The running owner fixes the direct
route, leaves the role unset so the project's job default applies, and records no
source, routine, browser session import or external Claude consent. A Claude task
created this way stays blocked before dispatch until the user grants consent with
`update --accept-external-policy`. Tasks start paused unless `--enable` is passed.
One-time schedules, deletion and immediate runs remain editor actions. Unknown
fields in the request fail closed; a lost acknowledgement is reported as uncertain.
