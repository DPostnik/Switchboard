# Portable work and route compatibility

Implemented 2026-09-27 from VISION stage 6. The stage-5 follow-up now adds an interactive Claude destination using an isolated
official-CLI subscription profile. Its authenticated live acceptance remains pending.

## Context handoff

The chat header opens **Hand off context**. The user enters the new goal and
instructions separately from historical decisions, changed files, actual checks and
remaining work. The saved transcript is optional and its completeness is disclosed.
The preview shows exactly the proposed draft. Oversized handoffs are rejected at
128 KiB; the user can exclude the transcript instead of silently truncating evidence.

Creating the handoff stores a versioned record in the app SQLite database, then
prepares a fresh Codex or Claude session with the explicitly selected project, agent and route under
the captured account revision. The draft is not submitted. A separate Send action
starts execution. Historical native references are evidence only; they never become
the new session ID. Source drafts, queues and approvals remain with their source.
Creation errors do not trigger retries. No tools or model are used to generate the
handoff in the background.

The destination chat retains the source conversation, connection/native reference,
snapshot revision and capture time. **Restore initial context to draft** explicitly
recovers the proposed handoff after a restart, only when the current draft is empty.
It does not send. Subsequent user edits belong to the resulting conversation, not to
the immutable source snapshot. Snapshots from unavailable integrations remain usable
as historical evidence. Claude destinations require its separate subscription login;
Claude optimizer routes remain visibly incompatible and cannot create a destination.

## Portable routines

Scheduled jobs → **Routines** opens the app-owned library. A version-1 definition has
an ID/revision, name, intent/applicability, expected inputs, constraints, ordered steps
with completion checks, required capability identifiers and optional agent-specific
instruction extensions. Definitions support 1–32 steps and up to 64 KiB. Unknown
requirements are retained and block mapping. Extensions for another agent block the
entire routine instead of being silently removed.

Saving a definition does not enable a schedule. Creating a task from it defaults to
manual, paused execution. An existing job can also explicitly select a routine. The
job receives a complete frozen definition, input and language; editing or deleting
the library entry does not modify that job. Each claimed run records the same frozen
invocation, so later job edits cannot rewrite past run provenance. Converting to plain
instructions is a separate explicit editor action that removes routine enforcement.

| Mapping | Behavior |
| --- | --- |
| Codex | Existing scheduled executor creates a new app chat using the selected route and current project permissions. |
| Claude Code | Existing pinned print-mode executor writes results into run history. Full-access project and explicit per-job external-policy consent are still required. |
| Unsupported capability or foreign extension | Visible editor explanation and a blocked outcome before executor dispatch; no alternate engine or prompt rewrite. |

Both mappings compile one structured prompt. The definition is approved instruction;
invocation input is labelled data. The agent is instructed to work in order, verify
each check, stop on an unverified/failed check, and report actual evidence. This is
not a deterministic per-step process runner or an independent check-result verifier.
The app never claims that a model's report proves a check passed. Existing durable
claims, concurrency, cancellation, imports and uncertain-run pauses remain unchanged.

## Optimizer compatibility

Process-plugin manifests may declare `optimizerRequirements`:

```json
{
  "protocolName": "openai-responses",
  "authentication": "app-codex-openai",
  "streaming": true,
  "toolCalls": true
}
```

This is the existing v1 profile; absent declarations on legacy v1 manifests have
exactly that meaning. Requirements describe the protocol/authentication boundary and
the features that must be preserved, not credentials. Unknown profiles remain visible
but cannot launch. The app and the process runtime both enforce the check. A manifest
cannot establish compatibility with another engine.

| Agent and route | Availability |
| --- | --- |
| Codex, no optimizer | Existing direct route. |
| Codex, process-plugin v1 (including Headroom) | Matching requirements, successful runtime handshake/status and a route declared by the pinned Codex adapter are required. |
| Claude Code, no app optimizer | Interactive chats use the isolated first-party CLI profile; scheduled jobs retain external CLI configuration. |
| Claude Code with an app optimizer | Unverified and unavailable. |

An unavailable or incompatible selected route is retained and explained; it never
falls back to direct. Existing plugin counters remain measured activity, not proof
of billing savings. Headroom's manifest explicitly declares the existing profile;
this change does not establish a new live-provider combination.

## Module distribution decision

Keep agent modules as separate in-process Swift targets for this stage. External
agent packaging/installation is deferred until a versioned transport, credential
boundary and compatibility/update policy are designed. Existing optimizer process
plugins retain their independent installation mechanism. Neither decision grants
universal engine/optimizer compatibility.

## Validation scope

Regression fixtures cover handoff provenance, fresh-session creation with no turn
submission, unchanged source queue/approval/draft, durable recovery, frozen routine
revisions, blocked mapping before execution, preservation of historical run revisions,
and rejection of incompatible optimizer processes. Russian/English prompt and error
copy are checked. Actual build/test results are recorded in `docs/improvements.md`.
These are synthetic protocol/model tests; no live-provider turn or interactive Claude
end-to-end acceptance is claimed.
