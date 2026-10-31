# Public preview validation — 2026-09-28

Historical record of the source-preview check before the first numbered release (1.0.0, 2026-10-31; see [CHANGELOG.md](../CHANGELOG.md)). Versions, counts and commit IDs below describe that day, not the current tree.

This record describes local preparation of the working tree based on commit `9945050`, including pre-existing uncommitted work. Nothing was committed, pushed or released by this task. It is not a statement that the remote repository already contains these changes.

## License follow-up — 2026-09-28

The author explicitly selected MIT after the initial preparation. Added the standard [MIT license](../LICENSE) with `Copyright (c) 2026 Daniil Postnik` and updated README. The text was compared with GitHub's MIT template, with only the year and author placeholders replaced. Links and whitespace diff were checked. This documentation-only follow-up did not change app code or rerun the build/tests recorded below; no commit or publication was performed.

## Environment and scope

- Apple Silicon, macOS 26.6.2 (25G83).
- Xcode 27.0 (27A266a), Apple Swift 6.4; selected macOS SDK under Xcode.
- Build/check Python: 3.14.6. Browser adapter also checked with the app's `/usr/bin/python3` 3.9.6.
- Discovered Codex: `codex-cli 0.158.0-alpha.2.1`; no new model request was sent during this preparation.
- Browser: Chrome DevTools MCP 1.10.1 with the already installed Node 23.10.0; isolated temporary Chrome profiles and a loopback fixture.

## Results

| Check | Result and limits |
| --- | --- |
| `zsh scripts/build-app.sh` | Passed; assembled and verified the ad-hoc signed workspace bundle. The running app was not restarted. |
| Fresh source directory | Passed release build in 61.09 s from a copy of tracked/nonignored working-tree files, without `.build`, `.git`, private app state or ignored `docs/`. SwiftPM resolved TOMLDecoder 0.4.5 from the machine's existing global cache. This was **not a clean Mac, clean account or cold-network test**. |
| `zsh scripts/test.sh` | 227 Swift tests passed in the final capture preparation, including protocol simulators and scheduler checks. Opt-in live model tests stayed disabled. The media probe runs separately. |
| Native media harness | One explicitly selected capture probe passed. It renders production `ChatView` and `JobsView` with synthetic data and never boots the app runtime. |
| Browser offline suite | 38 tests passed, including three close-confirmation regressions added during this preparation. |
| Code exercise | Baseline: five tests, two expected failures. Independent reference fix: five pass. The shipped exercise remains deliberately unfixed. |
| Real Chrome fixture | Both pages, four cards per pass, three passes: first result W-101/W-103; unchanged repeat no new IDs; changed snapshot new W-104. Final check passed with system Python 3.9.6. [Sanitized evidence](../media/browser-check.json). No model or scheduled job was invoked. |
| GitHub read-only check | Repository was public and Issues enabled; GitHub reported no project license. No issue or repository setting was changed. |
| Public files | Local links, YAML/JSON, whitespace diff and sensitive-pattern scan checked. PNG content inspected visually; captures use synthetic paths/data. |

The suite grew from 222 to 227 tests while unrelated mobile work was proceeding in the shared checkout. Those changes were preserved; their behavior is not attributed to this task.

## Problems found and handled

- README said the scheduler was a read-only viewer despite the current app-owned executor. It now distinguishes viewing/importing external definitions from running owned tasks.
- The previous README omitted Python from build prerequisites and referred readers to ignored documentation. Public instructions now live in `guides/`; the Swift Testing diagnostic links there.
- A real browser check observed an unconfirmed tab close. The exact timing cause was not established. The adapter now dispatches close once and allows a bounded read-only inventory check for delayed disappearance. Invalid/unconfirmed inventory stops the executor; no close action is replayed. Regression tests cover delayed confirmation, timeout and invalid inventory. A new isolated Chrome check passed after the change; this is not a guarantee that external browsers or sites never fail.
- The initial browser screenshot location was outside the adapter's temporary workspace and correctly rejected. Capture now happens inside that workspace before copying the synthetic image into the repository.
- macOS window capture failed with `could not create image from window`. AppKit could capture actual content panels, but not the outer composited navigation sidebar reliably. Published images are explicitly labeled panel renders, not full-window or live-agent evidence.

## Public-content review

Checked the current tracked files and nonignored additions for common credential formats, private key blocks, email-like strings and personal `/Users/...` paths. Candidate email strings in existing tests were synthetic fixtures; an initial broad key pattern matched a temporary-directory prefix, not a credential. The final credential/personal-path scan found no candidates in that scope. Public asset metadata and pixels were reviewed; only synthetic `/tmp/...` paths remain visible.

The ignored personal `docs/` directory, private application home, browser profiles, account histories and old Git objects are outside this scan. No credentials were copied, history rewritten or existing files removed. This is a bounded review, not a guarantee about the complete Git history or future changes. Raw machine logs and `build-info.json` were not copied into public media.

## Next for the source preview

On 2026-09-28 the author deferred the demo. The first showing can use README, MIT license, source build instructions, reviewed screenshots and written examples; no recording or live demo rehearsal is required for this scope.

1. Review the intended repository changes and publish them only in a separately authorized step, preserving unrelated work. The preparation changes are still local.
2. Align the first article and LinkedIn post with the documented capabilities and validation limits. Publication remains a separate action.

## Deferred checks and media

- The [80-second walkthrough](demo.md) and live demo rehearsals are deferred. Existing fixtures, captures and the shot list are preserved.
- These exact code/browser examples have not been run end to end through a newly authenticated app session and scheduled Run now. The production browser adapter and scheduler were checked separately; deferring the demo does not turn that into a completed end-to-end check.
- Independent build/onboarding on another Mac remains unverified. Intel and macOS 14 remain untested; the existing local build results retain their stated scope.

Headroom savings, Claude parity, cross-agent handoff quality, other browser-tool comparisons, mobile onboarding and notarized distribution were not validated by this preparation. None is a prerequisite for the Codex source preview when these limits remain visible.

## Files in this preparation

Existing public files changed: `README.md`, `BrowserRuntime/README.md`, `BrowserRuntime/server.py`, `BrowserRuntime/test_browser.py`, `scripts/swift-task.py`.

New public files:

```text
LICENSE
.github/ISSUE_TEMPLATE/bug_report.yml
.github/ISSUE_TEMPLATE/workflow_feedback.yml
.github/ISSUE_TEMPLATE/config.yml
guides/building.md
guides/examples.md
guides/demo.md
guides/validation.md
examples/code-fix/AGENTS.md
examples/code-fix/slug.py
examples/code-fix/test_slug.py
examples/browser-routine/AGENTS.md
examples/browser-routine/data.json
examples/browser-routine/serve.py
media/code-workspace.png
media/scheduled-task.png
media/browser-catalog.png
media/browser-check.json
scripts/capture-demo.sh
scripts/check-demo-browser.py
Tests/ContextCoreTests/PublicDemoCaptureTests.swift
```

The local-only improvement log was updated separately. Pre-existing and concurrent changes are outside this list.
