# Chrome DevTools integration

Source: user-approved implementation following the 2026-09-26 board, application
and authenticated LinkedIn benchmarks. This is an adapter, not a browser engine.

## Delivery sequence

1. Install and verify Chrome DevTools MCP 1.10.1 by published SHA-512; connect it
   through an app-bundled stdio adapter and an opt-in native settings control.
   Keep browser data under Switchboard and leave Codex/project policies intact.
2. Add compact selector-based card extraction, incremental scrolling, stable
   metadata checks, explicit partial results and bounded response sizes.
3. Verify navigation and pagination postconditions. Persist private checkpoints,
   at-most-once action records and per-session latency/byte counters.
4. Keep one upstream process and one token-owned work tab. Serialize requests,
   deny unknown protocol requests and latch uncertain transport outcomes.
5. Build the app, then validate Swift behavior, both copy languages, transport
   failure cases and real Chrome against local lazy-loading/no-op fixtures.
   Commit and push only after the build and required checks pass.

## Acceptance and limits

- Empty/loading lists and blank placeholders must not be called complete.
- A successful click must not imply successful pagination or submission.
- Reusing an action ID must never dispatch again, including after restart.
- Missing runtime must not prevent ordinary Codex use when browsing is disabled.
- No automatic browser login, credential copying, scheduler changes or model-turn retries.
- Existing native form tools remain available through a scoped action tool;
  submission confirmation is an explicit read-only verification, never a replay.
- Site selectors and task-level all-pages scheduling remain agent responsibilities.
  A saved page checkpoint is evidence, not permission to replay a prior action.
- This release adds metrics, but does not claim a measured production speedup.

Configuration reference: https://developers.openai.com/codex/mcp
Research and private benchmark artifacts remain outside published source.

## Delivered validation — 2026-09-26

The first integration milestone is implemented. The signed app build, 75 Swift
tests, 14 adapter tests, bundled real-Chrome fixture, real-Codex tool discovery
(enabled and disabled), and package verification passed. RU/EN copy reviewed.
No live Settings UI click-through or production speedup measurement is claimed.
Dedicated RAM sampling and automatic checkpoint resume remain future work; the
current checkpoint is durable evidence and never a replay queue.

## Manual sign-in follow-up — 2026-09-26

Source: user screenshot of Google's “This browser or app may not be secure” error.
The adapter now starts a dedicated Chrome in manual debugging mode and connects
with upstream `--browser-url`. It omits automation, disabled-sync and mock-keychain
flags. The same dedicated profile is retained; no user credentials are copied.
Chrome survives adapter shutdown. Reattachment checks the recorded PID, birth,
command, loopback listener ownership and browser endpoint ID before connecting.
Python bytecode caching is disabled to preserve the signed app bundle.

Signed build, 75 Swift tests, 21 Python tests, real Codex discovery of eight tools,
and package signature/source-digest/ZIP verification passed. Both languages were
reviewed. The real Chrome fixture verified native webdriver=false, lazy cards,
pagination, at-most-once fixture submission and reuse of the same Chrome process.
An initial reconnect fixture returned upstream “No page found”; the adapter did
not replay the operation. A fresh run and a further three consecutive reconnect cycles passed. The initial
missing-page cause was not established; stale page IDs are never silently rebound.
Google account acceptance was unverified at delivery. The subsequent manual
sign-in reached Google Account without a sign-in redirect; Chrome Sync was not tested.

## Browser lifecycle and live search follow-up — 2026-09-26

Source: user accepted lifecycle repair followed by a measured live search.
Implemented definite-exit/zombie handling, retirement of the old transport,
new-task-only relaunch via explicit browser_open, and invalidation of missing
page tokens. Ambiguous transport failure remains latched. No page is rebound by
URL or title and no action is replayed. Live EnglishJobs preflight exposed valid
clickout links longer than 2048 characters; URL capacity now matches the 8192
navigation limit while card count and other fields remain bounded.

The signed app build, 29 Python tests, bundled real-Chrome fixture (including
zombie restart, missing tab, duplicate action rejection and intact 2200-character
link query), actual Codex discovery of eight tools, and package verification
passed. RU/EN copy reviewed; Swift sources were unchanged in this follow-up.
The comparison uses the same
reference traversal algorithm at the direct MCP client boundary and inside the
adapter. It isolates aggregation and overhead, not model reasoning or a complete
morning job. Public pages only; no scheduler or applications.

Twelve live page reads passed: two EnglishJobs pages (20 cards each) and one
JustJoin Warsaw page (50 cards), with direct/wrapper/wrapper/direct ordering.
Mean three-page wall time was 35.92 s direct and 36.64 s wrapped. Client-boundary
calls fell from 106 to 9 and serialized responses from 2,567,832 to 97,297 bytes.
Peak driver RSS increased from 212.88 to 264.00 MiB; Chrome peaks were 2397.20 and
2410.61 MiB. This demonstrates aggregation, not faster browser execution or RAM
savings. EnglishJobs IDs matched exactly; JustJoin had 42 common IDs across four
50-card pages (58-ID union), so identical JustJoin coverage is not claimed.
The first direct round overlapped the isolated fixture check; two observations
per lane and changing live content do not establish a causal speed ranking.

Reproduction: run `python3 -B BrowserRuntime/benchmark.py` with `--resources`
pointing to the built BrowserRuntime, `--workload BrowserRuntime/benchmark-workload.json`
and `--output` pointing to a new private directory. Launch/warm-up are excluded;
RSS samples are process-tree sums, not unique physical memory. No model tokens
or reasoning time are measured. Reference client memory is recorded separately.
The first diagnostic run exposed URL clipping, was stopped after finding it,
and is excluded from the final comparison. Full morning traversal, qualification,
company/location extraction, and authenticated LinkedIn comparison remain future
work. The original intermittent page disappearance cause remains unestablished;
this change safely invalidates the token and allows a fresh explicit task.

## Workflow optimization — 2026-09-27

Compact metadata/pagination and opt-in static traversal shipped in the runtime; the
staged workflow plan from 2026-09-27 was retired with release 1.0.0 (its measurements
live in the local development notes). Scheduled jobs remain read-only.


## Independent chat browsers — 2026-10-01

Implemented persistent host-owned session bindings and per-thread MCP configuration.
Each chat gets its own Chrome process/profile, executor, operation queue, action
records and uncertainty fence. Runtime installation remains shared. The default
limit is two open managed browsers (configurable 1–8); admission never evicts a
browser or replays a rejected action. Native chat controls verify process identity,
synchronize explicit close with dispatch and persist close intent before signaling.
Disabled browser settings override saved thread configuration on resume.

Validation: signed scoped and main-workspace builds passed; 224 scoped and 242
workspace Swift tests passed with live installed Codex 0.159.2 checks enabled.
75 Python tests passed. The final bundled fixture verified two Chrome PIDs/ports,
concurrent native input, cookie and token isolation, independent progress during
blocked navigation (0.120 s for the other browser), disconnect fencing, retained
profile and explicit close isolation. Real Codex routing/restart checks use a
scratch home and one deterministic loopback HTTP 400 turn to persist the thread;
no remote model inference, credentials or production browser state are used.
The empty-thread and reserved-provider fixture setup failures were corrected
before the passing final runs. RU/EN copy and signed runtime bytes were checked.

Limits: inherited native subagents still use their parent's environment; automatic
per-subagent allocation is deferred. System input requires separate desktops for
full isolation. At capacity, opens are rejected before dispatch rather than held
indefinitely in a queue. No automatic eviction, credential sharing, manual UI
click-through, or memory/performance improvement claim is included.
