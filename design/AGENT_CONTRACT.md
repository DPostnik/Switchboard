# Agent integration contract v1

Implemented 2026-09-27 as stage 1 of [VISION.md](VISION.md). `Sources/AgentContract`
contains a Foundation-only Swift target, typed operations and events, preflight
validation and conservative delivery tracking. It has no engine transport imports,
native method names, arbitrary JSON or permission-answer payloads.

Execution paths use explicit app/native identity mapping (stage 2). Stage 3 is
implemented: `CodexIntegration` conforms to this contract, and production uses
`AgentClient` for interactive work, scheduled Codex submissions, history,
interactions and background generation. Stage 4 routes the scheduler through typed executors. Stage 5 delivers readable local
history and interactive Claude Code in an app-owned subscription profile, in live daily
use since 2026-10-07; a recorded two-engine acceptance run is still open. Stage 6
supports current execution paths (see `PORTABLE_WORK.md`). General optimizer
compatibility and externally installable agent modules are not delivered.

## Evidence and current capability matrix

This matrix describes the checked-in implementation, not all features offered by
either provider. Availability is connection-specific. An adapter must advertise
only verified capabilities at runtime; this table must not become an unconditional
capability switch.

| Operation | Codex | Claude Code (app profile, updated 2026-10-15) |
| --- | --- | --- |
| Identity | App-dedicated home; app manages sign-in/out | App-owned profile (`CLAUDE_CONFIG_DIR`); official `claude auth login --claudeai` subscription sign-in; no credentials copied from `~/.claude` |
| Interactive start/continue | Supported | Supported: stream-json process kept warm between turns, `--resume` on restart |
| One-shot scheduled execution | Creates app chat; app scheduler owns claim and ledger | Creates a continuable app chat through the shared chat executor (since 2026-10-09); the print runner remains only for injected test executors |
| Stream text/tool activity | Supported | Supported, including live sub-agent activity |
| Approval UI and user questions | Known requests supported; unknown requests rejected | Exact-input one-time approvals; single-select/free-text questions; multi-select and unknown controls fail closed |
| Interrupt | Turn interruption; transport loss can remain uncertain | Interrupt control; a missing terminal result stays uncertain |
| Native history/archive | Read/archive/unarchive supported | Native session kept in the profile for resume; archive/rename operate on app metadata |
| Portable local transcript | Normalized snapshots (stage 5) | Normalized, partial snapshots (stage 5) |
| Isolated title/summary | Separate ephemeral runner, bounded recipes, tools disabled, schema checked, pinned version | Separate `--print --no-session-persistence` process with no tools, MCP servers, settings, skills or slash commands, `--json-schema` structured output re-validated by the app, pinned version; never delegated to Codex |
| Models/effort discovery | Supported | No discovery; app-owned catalog over the configured model string. Documented `--effort` levels are forwarded; an unknown level is rejected |
| Token usage/account limits | Available where exposed by engine | Context occupancy from stream usage; plan limits through the CLI's experimental `get_usage` control request |
| Browser/workflow registration | App-owned browser launch settings and workflow roots; arbitrary live tool-server registration is explicitly unsupported | Switchboard browser as the only app MCP server; project `.claude/agents` in full access; claude.ai connectors and optional Claude in Chrome in full access; app workflow skills not registered |
| Optimization route | Explicit direct or available Responses plugin; engine-specific configuration | Direct only; no app optimizer route |
| Project permission intent | Standard workspace write/no network/ask; explicitly selected unrestricted/never | Standard: project file tools only (`--restricted`, no shell). Full access: `bypassPermissions`; attended turns hold claude.ai connector writing actions for approval, scheduled turns do not |

Evidence: `Sources/ContextDesk/DeskModel.swift`, `JobScheduling.swift`,
`Sources/ContextCore/Models.swift`, `Sources/ClaudeAdapter/ClaudeJobRunner.swift`,
`Sources/CodexAdapter/ArchiveSummaryRunner.swift`, `Sources/ClaudeAdapter/ClaudeGeneration.swift`, `BrowserConfiguration.swift`, `Sources/ContextCore/ProviderPlugin.swift`
and `RequestRoute.swift`. Claude Code is pinned to `2.1.292`; interactive and isolated
Codex paths accept `0.158.0-alpha.2.1`, `0.159.0`, `0.159.2` and `0.160.0`
(`CodexProtocolCompatibility`).
The interactive adapter checks the initialize response before advertising capabilities;
isolated generation additionally verifies its own configuration and empty tool inventory.
Validation uses synthetic providers; checking the installed version is not a paid/live
provider execution or installed-app UI acceptance test.

## Identity and ownership

`ConversationID` is an opaque app-owned string, distinct from `AgentSessionReference`;
new values use UUID strings. A native reference is scoped to both agent and
connection. Unknown agent IDs round-trip as unavailable identities, never as a
default engine. Stage 2 now migrates persisted associations without renaming legacy
keys or resuming queues; details are below.

`AgentContext` adds an account revision. Rotate it after account changes; reject
old model selections, submissions and approval answers. Adapters retain the opaque
mapping from app interaction IDs to native request IDs and invalidate it on
resolution, reconnect and account changes. `AgentApproval.accepts` checks identity
and offered choices; adapters must additionally enforce one-time consumption and
reject stale/unknown requests. Native request/answer encoding stays inside adapters.

App orchestration owns project selection, queues, scheduler policy, durable claims,
run history and display. Each adapter instance owns one connection. `submit` starts
a session when no native session exists; a scheduled Claude result may have no
session reference. `success(handle)` acknowledges submission, not task completion.
Events carry connection-scoped session references and opaque turn IDs so parallel work
is never associated through the selected chat. Submission handles additionally carry
request correlation and account context; completion outcomes are typed.
Unsupported operations return typed rejections; unavailable engines retain readable
records without dispatch or fallback.

## Permission and route validation

`AgentDescriptor.validate` checks exact contract version, current account context,
session connection, operation capability, available route and permission intent.
Workspace permission roots must match the requested project. The initial permission
support intentionally accepts only the combinations the current implementation
actually encodes; unverified combinations fail closed.

Claude's `externalPolicyDenyPrompts` is a distinct explicit policy. It MUST NOT be
inferred from either project access mode. Stage 4 rejects standard project
restrictions before dispatch and requires explicit per-job consent even on full-access
projects. Old and imported jobs have no implicit consent.
`externalConfiguration` exposes CLI-controlled routing without promising a direct
connection. Missing routes cannot be replaced by direct, another optimizer or agent.

The contract normalizes command/file/permission approval and text/choice questions.
An adapter rejects any native request or structured elicitation form that cannot be
represented faithfully; it must not drop restrictions or flatten unknown schemas
into an approval. Tool servers and workflow directories are app-owned descriptions;
registration returns unsupported when an engine cannot safely configure them.

## Delivery, cancellation and recovery

1. Validate while nothing has been sent. Rejection has no engine side effects.
2. Scheduler persists its durable claim before dispatch; adapter marks dispatch
   before any execution bytes can leave. Request IDs correlate work, not retries.
3. Acknowledgement associates the request with its engine handle. It does not mean
   completion and cannot clear an uncertain result.
4. Cancellation before dispatch is confirmed locally. After dispatch it is only a
   request until the engine confirms a terminal state. Killing a connection or
   losing an acknowledgement produces `uncertain`, including during cancellation.
5. A terminal state is immutable in the tracker. Late success after uncertainty
   needs explicit reconciliation; it never restarts a paused schedule or queue.
6. No adapter automatically replays any outcome. The app preserves existing
   uncertain-run pauses and requires explicit review/recovery. Reconnecting may
   read history; it must not resubmit work or answer pending approvals.

`AgentDeliveryTracker` tests these shared rules. Stage 4 adds a parameterized scheduler
fixture covering completion and uncertain recovery through both production executors.

## Isolated generation and history

Generation uses closed, versioned title/summary recipes, explicit model and route,
a source connection, and a 128 KiB UTF-8 upper bound. Each recipe may impose a
smaller bound. Adapters must independently verify tools-disabled ephemeral execution,
validate structured output, and reject unknown tool requests. Capability support and
preflight alone do not establish isolation. Cross-agent background generation is
rejected. Provider-specific JSON schemas remain private to adapters; structured
summary output preserves the existing overview/activity structure, including goals,
actions, outcomes, unfinished work, reusable steps, variable inputs and evidence.

Transcript snapshot schema v1 records app conversation ID, original native reference,
revision, capture time and completeness. Text/tool output stays literal historical
data. An unavailable or partial snapshot must never be displayed as complete; an
empty item list is not proof of completeness. Readers must reject unsupported schema
versions. Stage 2 implements schema storage/migration; stage 5 implements
engine-backed collection, backfill and readable history. No hidden engine state or cross-engine continuation is implied.

## Verification and remaining boundaries

Contract fixtures cover colliding session IDs, unknown-agent round trips, account
changes, missing routes, permission downgrades, cross-request approvals, cancellation,
ambiguous delivery and snapshot completeness. They do not execute providers or
migrate private app data. Existing regression tests still exercise current paths.
`python3 scripts/check-agent-boundary.py` ensures this target remains independent;
SwiftPM and the direct compiler fallback both include it.

The stage-3 command increment extends the dependency check to prohibit native
transport access and raw RPC dispatch in application/UI targets. The event increment additionally prohibits `JSONValue` and native method literals
in app/UI sources. The decoder increment also rejects native Codex history/usage/limit
field access in shared core. Full runtime contract adoption is implemented by the final stage-3 increment below. New app-owned UI copy must
be paired Russian/English when these types are connected to presentation; this
stage adds no product copy.

Validation on 2026-09-27: the signed app build passed with SwiftPM/macOS 26.5 SDK;
116 tests passed through SwiftPM and the direct compiler fallback (optional scheduler
UI rendering probe skipped). Bundle signature/source digest and contract dependency
checks passed. A duplicate-descriptor regression also fixed explicit scheduler lock
release; direct-runner compatibility and a pre-layout UI test assertion were corrected
during verification. Provider behavior is audited from source and existing fixtures,
not newly verified against live accounts. No app-owned copy changed.


## Identity migration (stage 2)

Implemented 2026-09-27. `Chat.id` is now the app key; `nativeSession` stores the
agent/connection/native-ID triple. Existing key values remain unchanged, including
non-UUID legacy fixture IDs. New chats receive an independent UUID string, persist
the mapping before submitting a turn, and never use an app ID as a native RPC ID.
`ConversationID`'s serialized string value remains compatible with UUID strings
from the stage-1 schema.

The original app-owned Codex home has the stable, store-local
`AgentConnectionID.originalCodex` identity. Legacy `model`/`defaultRoute` fields are
explicitly scoped by `SavedState.defaultConnection`; an unavailable default cannot
silently create a chat through the original connection. Other connection catalogs
and account lifecycle management remain part of adapter/interactive extraction.

The migration uses a SQLite `BEGIN IMMEDIATE` transaction, re-reads after taking
the write lock, validates unique app IDs and unique scoped native references, writes
explicit session associations and schema version 2, and parks unfinished summary
work. Commit failure rolls everything back. Unknown identity versions, missing
version-2 associations, malformed summary references and attempts to rebind an
existing app ID fail closed. Startup stops before connection/scheduler dispatch on
storage-load failure. Unknown integrations are retained, not converted to Codex.

All dependent keys are adopted together through **identity preservation**:

- Queues keep their app key, content, model, effort and project; startup remains paused.
- Usage, per-turn timings, archive summaries and unread completion IDs keep their keys.
- Drafts and running-turn/approval state use app IDs in memory.
- Scheduled-run JSON keeps its historical `threadID` field as an app reference;
  `JobRun.conversationID` exposes the typed interpretation. The file needs no rewrite,
  so there is no cross-file remapping window. Existing crash recovery keeps unfinished
  runs uncertain and schedules paused. Migration does not enable any schedule.

Outgoing read/resume/send/interrupt/rename/archive/delete requests resolve the
native session only for the original available connection. Incoming thread-scoped
Codex events resolve back to app keys before transcript, usage, completion, approval
or queue handling. Unknown thread-scoped requests are rejected and unknown events
are ignored. Identical native IDs on another connection cannot receive those events.
Background titles, summary execution and queue controls also check connection
availability. Route plugins belonging only to unavailable connections are not started.
These identity checks complement the stage-3 adapter, which now owns native
protocol handling in its separate target.

`transcript:<app-ID>` stores normalized snapshot schema v1, preserving the source
reference, revision, capture time and completeness. Save/read validates version and
source association; chat deletion removes its snapshot with metadata. This API does
not yet capture or backfill engine transcripts and is not a claim of offline history
availability. Existing metadata, summary content and job outputs remain readable;
opening engine-owned history still requires its original available integration.

Migration tests use synthetic SQLite/job files, inject a commit failure, verify
byte-preserving rollback and cross-file links, retain uncertain runs, exercise
colliding native IDs/unavailable connections, reject rebinding/future versions,
and check normalized event/usage routing. Existing send/queue/scheduler fixtures
verify native wire IDs differ from newly created app IDs. No private app data is
used for migration validation.

Stage-2 verification: final signed app build passed with SwiftPM/macOS 26.5 SDK on
2026-09-27, followed by all 123 tests (optional scheduler renderer skipped), contract
boundary, signature/source-digest and diff checks. New unavailable/storage errors
were reviewed in Russian and English. No live-provider turn, private-state migration
or installed-app click-through was performed.


## Codex extraction: command boundary (stage 3, first increment)

`CodexAdapter` depends on `AgentContract` and `ContextCore`; shared core and
transcript targets do not depend on it. Both SwiftPM and the direct compiler recipe
include the new target. `CodexConnection` and its JSONL buffer move out of shared
core. Native transport access is exported only through `NativeProtocol` SPI for
the diagnostic probe and protocol fixtures. At this increment, normal application imports used
`CodexClient`, which has no arbitrary request method. The final increment below
replaces those imports with the common `AgentClient` and an adapter composition root.

The client owns account/login/logout and model discovery RPCs, limit fetching,
workflow registration, session creation/resume/send/interrupt, naming,
archive/restore/delete, history reading and summary-source retrieval. Session
operations accept `AgentSessionReference` and reject an empty reference or a
foreign agent/connection before dispatch. History verifies the returned native
session ID and requires a turns array before exposing typed history turns. The
application retains persistence-before-send, queue state, scheduler policy and
ledger updates. Model selectors consume typed catalog entries; entries without a
model identifier are not offered. History timings retain stored token details.

The existing isolated runner moves unchanged, retaining its independent version,
configuration and tools-disabled checks. Browser launch settings and native
permission/provider encodings move into the same target. App-owned home selection,
route availability checks, plugin process lifecycle and workflow recipe ownership
remain with existing orchestration. No credentials or installed engine state move.

Historical scope of the first increment (superseded by subsequent increments):
the initial event/approval JSON bridge has now been removed by the increment below.
At that point, native parsers, interactive version gating, account
revision lifecycle, capability reporting and `AgentIntegration` conformance still
needed implementation. The command DTOs are transitional, not a second portable
integration contract. No interactive Claude path or offline history is enabled.

Stage-3 command-increment verification (2026-09-27): signed SwiftPM/macOS 26.5
app build passed, followed by 126 tests through both SwiftPM and a fresh direct
compiler build (optional scheduler renderer skipped). The added fixtures verify
wire permissions/native routing, rejection of foreign references before dispatch,
model decoding, sign-in URL validation and mismatched/incomplete history rejection.
Signature, current source digest, dependency boundary and diff checks passed.
Existing Russian/English copy was preserved and reviewed; localization fixtures
passed. These are local synthetic-provider checks, not live-provider or installed-UI
acceptance of the complete integration.


## Codex extraction: typed events and interactions (stage 3, second increment)

`CodexClient.events` now streams `CodexEvent`, with connection-scoped session
references and typed message/delta, usage, turn timing/completion, account,
diagnostic and interaction payloads. App orchestration maps sessions back to app
conversation IDs, persists usage/timing, updates notifications and owns queue and
scheduler policy. Application/UI code neither inspects native method names nor
constructs native JSON. Literal request details are display-only evidence.

Native request IDs stay in the adapter. The UI receives a fresh UUID handle and
can submit only a typed response. The adapter checks identity, allowed response
kind and required fields; it consumes the handle before awaiting the write, so
ambiguous delivery never invites a repeated answer. The transport independently
checks a process generation and request nonce immediately before writing. It
invalidates nonces as soon as it reads account changes, request resolution or turn
completion, closing the race while those events are still queued for presentation.
Disconnect and explicit stop invalidate all outstanding interactions. Duplicate
native request IDs cannot regain approval within the same connection lifetime.
Unknown or malformed requests and requests for unowned sessions fail closed.

Supported presentations preserve existing ordinary one-time command/file approvals,
plain text questions (including secret input), HTTPS tool links, plain string MCP
forms and simple legacy path/network permission requests. Command decisions are
restricted to those offered by the engine. `grantRoot` file requests, richer
entry/glob permissions and unsupported form constraints are shown without an
approval/submit control; explicit decline remains available. A constrained form
is never flattened into unrestricted strings. Native user content remains data.
These conservative limits are visible compatibility restrictions, not universal
support for every request type in the provider protocol.

Native schema evidence: generated locally from Codex CLI `0.158.0-alpha.2.1` with
`app-server generate-json-schema --experimental`, using a temporary `CODEX_HOME`.
This inspected the schema only; it neither authenticated nor executed provider
work. It does not establish interactive runtime version gating. At this increment the general
`AgentIntegration` account-revision/capability lifecycle was pending; the final
increment below implements it.

The transport has one scoped event stream. Its SPI JSON view is reserved for
isolated runners and diagnostics, avoiding a second unconsumed copy in production.
An oversized wire record closes the connection, invalidates approvals and emits
both an error and a disconnect on the current generation; filtering obsolete
process events must not hide that failure from scheduler/queue recovery.

Stage-3 event-increment verification (2026-09-27): final signed app build passed
with SwiftPM/macOS 26.5 SDK, followed by all 132 tests (optional scheduler renderer
skipped). Six new synthetic-provider tests cover decision/schema restrictions,
scoped single-use answers, transport-time invalidation, unknown/repeated requests,
old generations, turn resolution, timing/missing usage and oversized-input recovery.
Existing routing, notice, queue, scheduler, isolation and persistence fixtures passed.
Russian/English copy was reviewed; boundary, signature/source digest and diff checks
passed. No live-provider approval or installed-app click-through was performed.


## Codex extraction: native decoders (stage 3, third increment)

`CodexDecoding` is internal to `CodexAdapter`. It decodes account limit buckets,
cumulative token counters, context usage, transcript items, timing and archive
summary source history. App/UI code cannot access these helpers. Core models now
have value-based initializers; storage, token differences, display formatting and
bounded summary chunk assembly remain independent of Codex payloads. Summary
source digests, evidence references, Unicode segmentation and rejection of active,
incomplete or duplicate history are preserved. The JSON value utility remains in
core for app-owned structured-output schemas and existing plugin/Claude job data;
it is not itself a Codex transport API.

The dependency check rejects native Codex history, usage and limit field access
in core as well as existing app/UI protocol bypasses. Existing decoder fixtures
now exercise the internal adapter, while migration and queue fixtures construct
normalized usage values. At this increment, full `AgentIntegration` conformance and connection/version/
capability lifecycle were pending; the final increment below completes them.

Stage-3 decoder verification (2026-09-27): signed app build passed with
SwiftPM/macOS 26.5 SDK, followed by 133 passing tests (optional scheduler renderer
skipped). Source-digest stability and active/duplicate history rejection have
explicit regression coverage. Bundle source digest/signature, boundary rejection
fixture, preserved Russian/English pairs and diff checks passed. No live-provider
or installed-UI acceptance was performed.


## Codex extraction: production contract adoption (stage 3, final increment)

`CodexIntegration` implements the Foundation-only `AgentIntegration` protocol.
`AgentClient` is an engine-independent core convenience layer; only the app's
composition root imports `CodexAdapter`. The dependency check rejects direct native
clients/runners, adapter imports elsewhere in app/UI, raw payloads/RPCs and shared-core
native decoders. `ContextProbe` and protocol fixtures retain diagnostic SPI access.

The concrete contract preserves the shipped application's needs: preparation is
separate from submission so app chat/job associations are durably saved before a
turn; normalized history preserves turn boundaries and timing; events preserve
session/turn identity, unknown usage, typed outcomes, single-use approval handles,
questions, constrained forms and tool links. A nil native session on submission
creates one; an existing session must first be prepared under the same account
revision and route. Empty interactive model IDs explicitly request the engine's
default, while background recipes require a named model. Portable snapshot storage
remains app-owned; stage 5 now populates normalized snapshots (see below).

Capabilities are advertised only for a running, version-compatible connection.
Account revision rotates at the transport when account events arrive, on explicit
sign-out and when the process changes. The adapter validates typed permission,
connection and route intent; the transport independently rechecks the captured
revision immediately before writing. Late results from an old account are not
accepted as current catalog/history data. Confirmed logout is allowed to rotate
its own account revision. Prepared work cannot silently adopt a new account or
route, and used request UUIDs cannot resend work. Cancellation is scoped to known
session/turn/account tuples; disconnect or lost acknowledgements remain uncertain.

Generation uses the same contract, explicit source/model/route and a cancellable
request ID. Each title/summary still runs in a separate ephemeral process with
pinned version, tool inventory, sandbox and schema checks. The durable summary
claim runs only after isolation checks and before dispatch. Pre-dispatch cancellation
does not launch work; account changes stop active generators and pause pending
summaries for review. Neither failure nor uncertainty triggers a replay or fallback.

The app supplies optimizer endpoints and browser/workflow intent. Codex adapter
code owns Responses-provider arguments, the optimizer's app-home environment,
browser launch encoding and executable discovery. Plugin process supervision and
app workflow/recipe ownership remain in core/application. No existing external
credentials, engine homes or schedules are copied or changed. Arbitrary runtime
MCP-server registration is not advertised; the supported browser is configured at
connection startup. Stage 4 subsequently replaces the scheduler engine branch and
migrates the existing Claude print runner, rejecting unsupported project restrictions.

Final stage-3 validation (2026-09-27): `zsh scripts/build-app.sh` passed with
SwiftPM/macOS 26.5 SDK, then `zsh scripts/test.sh` and `zsh scripts/test.sh --direct`
each passed 138 tests (optional scheduler renderer skipped). Existing app fixtures
now run through the production contract adapter, including parallel chats, queue
routing, interruption, archive/history, isolated titles/summaries and scheduled
Codex jobs. Five runtime tests cover incompatible-version shutdown, stale prepared
work and transport-time account checks, confirmed logout, permission/route rejection,
duplicate submission, uncertain acknowledgement and cancellation before generation.
Bundle signature/source digest, dependency rejection fixtures, paired Russian/English
copy review and diff checks passed. Installed CLI version was checked read-only;
no live-provider model turn or installed-app UI interaction was performed.


## Scheduled executors (stage 4)

Implemented 2026-09-27. `AgentScheduledExecutor` is the narrow scheduled-execution
contract in the Foundation-only target. It consumes `AgentExecutionRequest`, advertises
`AgentDescriptor`, returns typed terminal or deferred outcomes, and supports stop.
It avoids falsely claiming that print mode implements interactive `AgentIntegration`.
`AgentIntegrationFactory` registers the executors and automatic-start readiness.
The scheduler no longer dispatches or stops native runners by engine-specific branches.

`CodexScheduledExecutor` is app orchestration: it validates the bound job and descriptor,
then preserves chat creation, durable session/turn links and existing typed integration
submission/events. Deferred results stay active until the matching event; the executor
remains available for stop. `ClaudeAdapter` owns CLI discovery, pinned `2.1.292` checks,
arguments, process capture and decoding. Core/UI cannot access its runner outside the
composition root. The direct-build module/link recipe includes the separate target.

Claude descriptors declare external CLI identity and external configuration routing,
scheduled execution and interruption only. Each one-shot executor gets an ephemeral
context; this is not a verified external account identity or account-management API.
No credentials are copied and CLI routing is not represented as verified direct routing.
A legacy direct route means no app optimizer, with external routing disclosed in UI;
non-direct app routes are rejected. Effort overrides are forwarded to the CLI as
`--effort` when they name a documented level (low, medium, high, xhigh, max); any other
nonempty value is rejected before dispatch.
Explicit external-policy consent is stored as an optional field, absent on legacy/imported
jobs. Only a full-access project plus that consent creates `externalPolicyDenyPrompts`.
Standard workspace/network restrictions always fail closed, even with the consent flag.

A durable running claim is written after CLI version validation, before model dispatch.
Failed persistence prevents execution. Duplicate execution on a consumed executor is
rejected. Cancellation before dispatch is cancelled; cancellation or malformed output
after process launch is uncertain. These outcomes pause the schedule and never replay.
CLI authentication remains external; stage 4 does not establish interactive Claude's
app-owned configuration boundary or enable background generation, tools or metrics.

Validation and actual build results are recorded in the stage-4 entry of
[improvements.md](docs/improvements.md). Provider fixtures are synthetic, not live turns.

Update 2026-10-09: Claude tasks now use the same chat executor as Codex
(`ChatScheduledExecutor`, renamed from `CodexScheduledExecutor`). Each run creates a
Claude chat in the app profile with the task's model/effort, the project's access mode
and the per-run browser; replies continue the same session. The external-policy consent
and the external-CLI descriptor above apply only to the print runner, which remains for
injected test executors.

## Readable local history (stage 5)

Normalized snapshots now populate through the original adapter's typed history read,
startup backfill, turn-completion refresh and item events (including unselected chats).
The app reads snapshots before attempting an engine refresh; unavailable engines retain
readable chats and archives. Backfill reads only and never prepares/resumes a session,
changes selection, transfers approvals, or drains queues. Failed reads retain the last
snapshot. Capture timestamps prevent late reads from replacing newer item events.

The v1 snapshot adds optional presentation fields for phase, turn identity and response
timing; old items without them remain readable. Revisions hash normalized content.
The Codex adapter reports complete only for terminal turns whose items are fully
represented text messages. Tool details, attachments, unknown items and active turns
produce partial snapshots. Streaming deltas are not a durable write-ahead transcript:
only item events and successful history reads are persisted, so an interrupted stream
can leave incomplete text until a later successful read. Snapshot notices disclose this
and distinguish missing local data from an empty conversation.

This describes the first local-history slice of stage 5. The interactive Claude
follow-up is documented below; a recorded two-engine live acceptance run is still open. Live-provider/UI verification remains separate from the
synthetic adapter and model regression tests.

## Portable work and optimizer compatibility (stage 6)

See [PORTABLE_WORK.md](PORTABLE_WORK.md) for definitions and scope. Handoff prepares
a new session under a captured account context, stores provenance, and leaves the
prompt unsent. Source references appear only as historical evidence, never as the
destination session argument. No source queue entry or approval is transferred.

`RoutineInvocation` freezes a portable definition, input and language. The scheduler
checks capability IDs and agent-specific extension ownership against the executor's
actual descriptor before `execute`; unsupported mappings produce a blocked run.
The existing descriptor/adapter still enforces route, model and permission policy.
The run ledger retains the exact definition revision independently of future edits.

Optimizer requirements are an optional additive field in process-plugin manifests.
Legacy v1 means the fixed Responses/app-Codex-auth/streaming/tools profile, not a
claim of multi-agent compatibility. Both application setup and the plugin runtime
reject incompatible profiles before process launch. Runtime route availability and
pinned adapter-version checks remain independent requirements. No new provider
combination or savings guarantee is inferred from a manifest.

## Interactive Claude subscription profile (stage 5)

Current state (2026-10-15): the user signed in with a Claude subscription on
2026-10-07, and interactive chats, resume, archive summaries and scheduled runs work
live. Changes since the original text below: processes stay warm between turns
(restart with `--resume` when the launch changes, after failed/uncertain turns or
idle); full-access chats drop `--safe-mode`, load the account's claude.ai connectors
(writing actions ask in attended turns), the project's `.claude/agents` and optionally
Claude in Chrome; both modes get the Switchboard browser; titles and archive summaries
use the isolated Claude generation runner; the app passes the project's AGENTS.md, the
profile's global `CLAUDE.md` and its commit attribution explicitly because setting
sources stay empty; sub-agents are shown live and their results can resume the chat.
Model discovery remains an app-owned catalog. The paragraphs below are the 2026-09-27
design record; statements contradicted here are superseded.

The app now composes `ClaudeIntegration` alongside the existing Codex integration.
New chats explicitly select an agent. Native references, pending interactions,
queues, stop/history/archive operations and disconnect cleanup resolve by connection;
a Codex failure does not reset a Claude turn. Titles, archive summaries, browser,
workflows and model discovery remain unavailable for interactive Claude.
Context/token usage (2026-10-07) is decoded inside `ClaudeAdapter` from main-thread
stream-json usage blocks: occupancy is the latest call's uncached + cache-created +
cache-read input plus output; the window comes from the terminal `result`'s
`modelUsage[model].contextWindow`. `result.usage` is per turn, while `modelUsage`
accumulates across `--resume`, so only its window is read. Cumulative counters, window
and last occupancy persist in the adapter session record; subagent calls are excluded.
The model field accepts an explicit Claude model or an empty engine default.
Scheduled Claude jobs retain their existing external-CLI path and consent rules.

Authentication uses the installed official Claude Code **2.1.292** binary. Settings
opens a generated local `.command` running `claude auth login --claudeai`, with an
allowlisted environment and `CLAUDE_CONFIG_DIR` inside the app-owned home. The user
completes the subscription login in Terminal and clicks **Check sign-in**. No API-key
entry, copied credentials, custom OAuth client, external profile import or Console
login is provided. According to the [official authentication documentation](https://code.claude.com/docs/en/iam),
`CLAUDE_CONFIG_DIR` scopes the macOS Keychain entry as well as credential files.
This is a personal official-CLI integration; it is not a claim of authorization to
redistribute a third-party subscription-authentication service.

Execution uses the CLI's stream-json input/output, partial events, stdio permission
control, initialize and interrupt messages. Native protocol stays in `ClaudeAdapter`.
The bridge is based on the [official SDK control implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py)
and checked against the pinned local CLI. Each user turn starts a process, with an
explicit session UUID for the first turn and `--resume` for later turns. There is no
automatic replay. Unknown control requests, malformed JSON, mismatched sessions and
transport loss stop the process. Dispatched work without a terminal result is uncertain.
Interrupt acknowledgment alone does not imply completion; a missing terminal result
closes the process after a grace period and remains uncertain.

Standard access deliberately offers **project files only**, not shell execution:
`--restricted --tools Read,Glob,Grep,Write,Edit,AskUserQuestion`, default permissions,
no app-added network tools. Full access uses the project's explicit unrestricted
mode. Both use safe mode, empty user/project/local setting sources and strict empty
MCP configuration. No app optimizer route is available. Permission responses allow
only the exact tool input once; native permission-update suggestions are not applied.
Only single-selection/free-text question schemas are supported; multi-select and
unknown controls fail closed. Account checks precede dispatch, and a changed account
invalidates old requests and interaction tokens. A malformed account response cannot
reuse an earlier signed-in state.

Adapter records in `claude/contextdesk-sessions` persist a claim before prompt bytes
are written. Item events and terminal turns feed the shared SQLite snapshots. Claude
snapshots are partial: the app retains normalized text/tool activity, not a complete
native execution log, and interrupted text deltas may be absent. Native files remain
in the isolated profile for resume. Archive/rename operate on app metadata; deleting
a chat hides it locally and does not purge native CLI history or the source handoff.

Validation distinguishes protocol fixtures from an authenticated provider session:
fixture tests cover durable dispatch, streaming, resume, replay rejection, approval
and question correlation, outside-project denial, unknown/malformed frames,
interruption, changed/invalid authentication, scoped disconnects and Claude handoff/
archive metadata. The installed CLI returned a successful initialize control response
with the production standard-mode flags in an empty isolated profile; isolated auth
status reported signed out. On 2026-09-27 real subscription sign-in was deferred because no Claude subscription
was available; it has since been used live (see the current state above). The recorded
two-engine start/interrupt/resume/archive acceptance run is still open.

### Available final verification, 2026-09-27

The final local build and 164 regression tests passed. Native production views were
rendered with fixture stores in Russian and English; this is not a claim of full UI
automation. The archive banner no longer claims a local snapshot necessarily exists.

Live Codex checks using only the app-owned profile verified response/history,
context retention after a fresh connection, rename/archive/restore, and readable
SQLite snapshots after engine disconnect. A streaming interruption received both
an acknowledgment and the matching cancelled event. An earlier immediate interrupt
RPC returned an error despite a native interrupted record; that attempt was not
retried or counted as an acknowledged stop. Existing queues, permissions and native
references were not transferred, and only newly created test sessions were archived.
Claude's subscription-dependent acceptance remains deferred. Detailed local evidence
and limitations are recorded in `docs/validation-stage5-2026-09-27.md`.
