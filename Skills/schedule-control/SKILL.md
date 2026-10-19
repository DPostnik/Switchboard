---
name: schedule-control
description: Inspect, create, import, edit, enable or pause Switchboard recurring tasks through the running scheduler. Transfer originals only through an available supported source-scheduler tool.
metadata:
  description-ru: Создание, импорт, изменение, включение и пауза постоянных рутин через планировщик Switchboard.
  description-en: Create, import, edit, enable and pause ongoing routines through the Switchboard scheduler.
---

# Schedule control

Use `scripts/schedule-control.py` with Python 3.9+ and the running app. Never edit its ledger, external schedule files, credentials or locks. This channel does not run immediately, delete jobs, create or convert one-time runs, or grant project permissions.

- `list`: current app jobs and their instructions.
- `create --name NAME --project-id UUID --prompt-file FILE --rule RRULE --time-zone ZONE --model MODEL --effort EFFORT [--engine codex|claude] [--enable]`: creates a new app-owned recurring task at the user's request. Read `catalog` first for project IDs. The rule must be in the supported recurring subset (see `update`). The task is **paused** unless `--enable` is given; `--enable` is allowed only when the user asked for the task to run. The owner fixes the rest: direct route, the project's job role, no source, no routine, no browser session import and no external Claude consent. A Claude task therefore stays blocked before dispatch until the user grants `--accept-external-policy` through `update`. The reply lists all jobs; find the new one by name and keep its `id` for later edits. A completed reply is a saved definition, not a run result.
- `catalog`: current readable Codex source definitions with content digests, app jobs and existing project IDs/paths. Unreadable/unknown definitions are excluded; absence is not proof of deletion or pause. This does not list cloud ChatGPT Tasks.
- `import --source-id ID --project-id UUID --time-zone Europe/Warsaw --model MODEL --effort EFFORT --recurring [--prompt-file FILE]`: creates one **disabled** copy. It reads a fresh catalog, compares the source digest on execution, preserves the exact RRULE, and rejects duplicate sources. Pinned source model/effort must match. For inherited settings, resolve explicit choices from authorized context; do not claim source-thread settings were imported. `--recurring` attests that this is ongoing work: one-time tasks and finite pilots are excluded, even if their syntax is repetitive. The scheduler additionally rejects COUNT/UNTIL and unsupported rules. No source session is resumed.
- `update --job-id UUID [--prompt-file FILE] [--rule RRULE] [--time-zone ZONE] [--enable | --pause] [--confirm-source-disabled] [--model MODEL --effort EFFORT] [--accept-external-policy | --revoke-external-policy]`: changes an existing job through its owner; project, engine, route and permissions remain unchanged. `--rule` replaces a recurring schedule (the app's supported subset: `FREQ=MINUTELY|HOURLY;INTERVAL=N`, or `FREQ=DAILY|WEEKLY` with `BYHOUR`, `BYMINUTE`, optional `BYDAY`, `BYSECOND=0`); `--time-zone` changes its IANA zone. Omitted parts are preserved, unsupported rules are rejected, an enabled job's next run is recalculated, and one-time jobs stay in the editor. Change the schedule only at the user's request and verify `schedule` and `nextRun` in the completed reply. `--accept-external-policy` records the editor's per-task Claude consent and is accepted only for Claude-engine tasks; use it only when the user explicitly asked for that task's consent in the current conversation. Model and reasoning change only when both explicit flags are supplied under user authorization; omitted values preserve the current pair. Model availability is verified by execution, not by a successful configuration write. Frozen routine definitions still require the routine editor.
- `status REQUEST_ID`: inspect the existing receipt without resubmitting. Each request prints its ID. Timeout or uncertain persistence is not authorization to retry, including imports with a new ID.

## Authorized recurring transfers

The user's standing authorization of 2026-09-27 permits selecting ongoing routines, disabling their originals and enabling checked copies without asking again for each transfer. Preserve scope, source coverage, time zone, permissions and pending evidence. This does not authorize sending messages or executing the routine during migration.

1. Inspect `catalog`, canonical workflow and current app jobs. Reject finite tasks and duplicates. Prepare the destination prompt, project and explicit inherited settings. Import disabled and verify the returned job before touching the original.
2. Discover an available **supported source tool**, such as `automation_update` in the source app. Read its actual schema. Read the exact source and check active-run state if supported. Use only its pause operation for the selected source; never substitute direct TOML edits, another scheduler, credentials from another app, guessed IPC or a model turn in the old thread. No source tool is bundled with this skill. If absent, report that concrete blocker and leave the copy disabled.
3. Confirm the pause through a fresh source-tool read and the matching source definition. If the original has an active run or its execution state is unknown, do not enable the copy until that uncertainty is resolved. An uncertain pause response must not be repeated automatically. Do not resume the original as automatic rollback.
4. Compare current instructions/schedule with the imported snapshot; resolve any drift before enabling. Use `update --enable --confirm-source-disabled` only after the exact original is confirmed paused. The app independently verifies the local Codex definition. This flag records observed confirmation; it does not require another user question within standing authorization. Claude/unknown imports remain outside this channel.
5. Verify prompt, source, project, enabled flag, schedule/timezone and nextRun in the completed response. A configured task is not proof of a successful run. Do not run a production task just to test migration.

Unclaimed requests expire after 60 seconds; claimed requests never replay after a crash. Updates reject concurrent edits and active runs. Keep checkpoints private. The app must remain open and the Mac awake. A newly built control capability requires Cmd+Q/reopen; never interrupt a running user session automatically. If an installed editable skill is older, use the matching bundled client until it can be updated without overwriting user edits.

## Standing browser session import

For explicit user authorization covering a selected task/site/source Chrome profile,
use `python3 scripts/browser-import.py --job-id UUID --chrome-profile Default --site linkedin.com`.
Use `--site '*'` for any site; each run then imports only the cookies Chrome would send to the page that lacks sign-in.
Use `--disable` without profile/site to revoke for future runs. Read the observed
job first. This stores permission metadata only; it never imports cookies immediately,
changes the prompt/schedule/model/project permissions, enables a task, or runs it.
Every new Codex or Claude Code run receives the site permission in its own browser environment
and conditional sign-in recovery instructions (Claude Code calls the tool as
`mcp__switchboard_browser__browser_import_session`; with the browser disabled the run is blocked). Regular Chrome may stay open;
Keychain may need a user grant. Cookie readback is not website sign-in verification.
Never auto-close Chrome, retry an uncertain import, or expand the site's action scope.
An old running app rejects `browser-import`; ask for Cmd+Q/reopen of the verified
build before submitting again. Inspect an uncertain receipt with `status`, never replay.
