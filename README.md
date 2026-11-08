# Switchboard

A native macOS workspace for working with AI agents across local projects, conversations, and recurring tasks. Built with SwiftUI and AppKit around the Codex App Server and the Claude Code CLI.

**Version 1.0.0, built from source** ([changelog](CHANGELOG.md)). Start with either agent in Direct mode; each new chat names its agent. This is an independent personal project, not an official OpenAI or Anthropic application.

![Switchboard code conversation](media/code-workspace.png)

*Actual application views rendered with synthetic demo content. This is a UI preview, not evidence of a live model run. [Capture provenance](guides/demo.md#captures-and-provenance).*

## Why I built it

Over the last six months I moved from Cursor to daily work with agents in Claude and OpenAI’s apps. I currently prefer OpenAI’s products, but I wanted an interface I could shape around my own projects and routines, with room to change the underlying agent later.

I also kept running into usage limits. That led me to investigate context management and Headroom. The integration work became another reason to build my own workspace. **Measured resource savings and interchangeable agents are development goals, not promises of this preview.**

## What you can try

- **Fix code in a project folder.** Open a folder, start a chat, inspect tool activity, respond to approval requests, and read the result. Conversations, drafts, queued follow-ups and unread replies stay organized by project.
- **Keep several conversations going.** Each chat has its own turn, queue and Stop control. A failed or uncertain request is not automatically resent.
- **Work with Codex or Claude Code.** Choose the agent and model per chat. Claude chats show sub-agents live, can use the project's `.claude/agents`, and in full-access projects can reach the account's claude.ai connectors and, optionally, your own Chrome through Claude in Chrome.
- **Read files from answers.** Links to project files open in a side preview that can expand to the whole window; files can be dropped anywhere on a chat.
- **Read a website with an agent.** The optional Switchboard browser runs a separate Chrome for Testing with a profile per chat. Agents read pages as element trees with stable refs, act by ref, take screenshots, upload project files and extract compact card data. Site sign-ins come from a manual login or an explicit cookie import from your Chrome. Try the local Workshop Watch fixture before using real sites.
- **Repeat a task while your Mac is awake.** Create an app-owned scheduled job for Codex or Claude Code. Each run opens a chat you can read and continue; the run history keeps outcomes. Closing the window keeps the app running; quitting stops the scheduler.
- **Inspect usage without guessing.** Context estimates, reported token counts and account limits are separate. Missing measurements stay unknown. They do not prove a reduction in subscription usage.

The interface supports English and Russian. In **Settings → Язык / Language**, choose English and restart to apply it. Interface zoom scales the window for large displays. Projects and chats use the app’s own storage; existing desktop Codex or Claude conversations are not imported.

## Two reproducible examples

| Example | Task | Observable result |
| --- | --- | --- |
| [Code fix](guides/examples.md#1-fix-a-small-python-function) | Fix whitespace handling in a tiny Python function | Five acceptance tests pass; a one-line implementation change |
| [Browser routine](guides/examples.md#2-check-a-local-workshop-catalog) | Read two catalog pages and report newly available frontend workshops | First pass: W-101 and W-103; changed snapshot: W-104 is new |

Both use synthetic data and the Python standard library. The guide distinguishes local fixture verification from a live agent run. Agent responses and latency can vary.

![Workshop Watch local browser fixture](media/browser-catalog.png)

*Real Chrome capture of the included local fixture. [Setup, prompt and expected output](guides/examples.md#2-check-a-local-workshop-catalog).*

## Quick start

You need a Mac, a matching **Swift 6 / Xcode or Command Line Tools** installation, **Python 3.10+**, Git and internet access for the pinned Swift dependency. The deployment target is macOS 14; validation so far is on Apple Silicon with macOS 26.6.2 and Xcode 27 / Swift 6.4. Intel and macOS 14 have not been tested.

```sh
git clone https://github.com/DPostnik/Switchboard.git
cd Switchboard
python3 --version
xcrun swift --version
zsh scripts/build-app.sh
zsh scripts/test.sh
open 'build/Switchboard.app'
```

The build creates an ad-hoc signed local app. It does not need an Apple Developer subscription, a DMG, Headroom, Node.js or a model account. The build runner uses Python; ordinary Direct chats do not run a Headroom process.

To **use agents**, install the [official Codex CLI](https://learn.chatgpt.com/docs/codex/cli), or have a supported ChatGPT/Codex desktop installation. To keep Codex independent of desktop app updates, run `zsh scripts/install-codex-cli.sh` (requires npm). Switchboard prefers this verified CLI in its own application support folder; without it, it discovers the desktop or system CLI. Codex is not bundled. On AC power, after a clean nightly suite, Switchboard stages newer stable npm releases separately and checks their protocol, account/model discovery, isolation and plugin chat resume in a temporary profile. Only a clean pass selects the tested binary for the next connection; the previous installation remains available. Open a disposable project folder, choose **Sign in**, and complete the separate ChatGPT sign-in. An account with Codex access and network access are required; normal account limits apply. Select an available model and keep **No plugin** selected for the first run.

For **Claude Code**, install the [official Claude Code CLI](https://code.claude.com/docs). In Settings, **Sign in** opens the official `claude auth login --claudeai` in Terminal with the app's own profile; then choose **Check sign-in**. A Claude subscription is required. Your existing `~/.claude` login, settings and history are not used or copied.

Verified engine versions: Codex `0.158.0-alpha.2.1`, `0.159.0`, `0.159.2` and `0.160.0`; Claude Code `2.1.292`. Both protocols are evolving; a newer CLI is not automatically a verified replacement, and Codex archive summaries refuse unverified versions. [Build guide and troubleshooting](guides/building.md) · [Validation scope](guides/validation.md).

## Optional integrations and boundaries

| Component | Current scope |
| --- | --- |
| Codex | Local engine, separate app home, streaming chat, tools and approval UI. Available models come from the engine/account. |
| Claude Code | Interactive chats and scheduled runs in a separate app profile with subscription sign-in. Standard projects get project-file tools only; full access runs the CLI without prompts and adds claude.ai connectors (writing actions still ask), the Switchboard browser and optional Claude in Chrome. Context usage and plan limits are shown where the CLI reports them. Permission semantics differ from Codex's sandbox. |
| [Browser](BrowserRuntime/README.md) | Opt-in. Pinned Chrome for Testing 154 and Chrome DevTools MCP 1.10.1 with the app's own page tools; requires Node.js 22.12+. The app launches it with `/usr/bin/python3` (tested: 3.9.6). Install the pinned runtime, then enable Settings → Browser. Each chat gets its own profile and tab; a chat's idle browser quits after its last task tab closes. |
| [Scheduled jobs](design/SCHEDULED_JOBS.md) | App-owned Codex and Claude Code schedules, run chats and run history. The app must stay open and the Mac awake. Imports start paused; do not enable a copy while its original still runs. |
| [Headroom plugin](plugins/headroom/README.md) | Separately installed experimental proxy integration. Not needed for the main demo. This preparation did not verify live routing, quality or resource savings. |
| [Mobile companion](Mobile/README.md) | Experimental native iPhone app synced through your own Supabase project: read and continue chats, answer questions and approvals, start Codex or Claude chats. Needs Xcode signing and extra setup; not needed for the Mac quick start. |

Archive summaries make additional model requests and consume allowance. Context percentages are estimates; plugin counters and browser RPC timings are not billing measurements. Unknown outcomes stop for review instead of triggering automatic retries.

## Data and permissions

Private state lives in `~/Library/Application Support/Switchboard/`: metadata, the dedicated Codex home and Claude profile, conversations, schedules, optional browser profiles/checkpoints and installed plugins. Agent requests still go to the configured provider; this is not an offline model. The optional mobile integration has its own data path and setup.

Switchboard does not copy your existing Codex or Claude credentials. Project permissions and approval requests still apply. Review the scope before approving a command. Never publish the application data directory, auth files, raw conversations or browser profiles. Use the synthetic examples for screenshots and issue reports.

## Next

This source preview includes screenshots and written examples. A recorded walkthrough is deferred.

- Verify onboarding and build steps on a separate Mac and more supported OS versions.
- Compare browser approaches on repeatable tasks; report coverage and failures alongside timings.
- Validate agent interoperability and Headroom with task-quality checks and provider-reported usage before making savings claims.
- Consider signed/notarized distribution separately from this source preview.

## Feedback

[Open a GitHub Issue](https://github.com/DPostnik/Switchboard/issues/new/choose) for a reproducible bug or a concrete workflow you tried. Include macOS/chip, Swift and Codex/Claude Code versions, the relevant demo step and redacted error text. Please review screenshots for account names, private project names and local paths. Issue templates are included in this repository.

## License

[MIT License](LICENSE) — Copyright (c) 2026 Daniil Postnik. Third-party components retain their own licenses.

---

[Build guide](guides/building.md) · [Examples](guides/examples.md) · [Screenshot notes](guides/demo.md#captures-and-provenance) · [Checks and limitations](guides/validation.md) · [Project direction](design/VISION.md)

Public reader documentation lives in `guides/`, design notes in `design/`, the version in `VERSION` and user-visible changes in `CHANGELOG.md`. The ignored `docs/` directory contains local development notes and is not required to build or try these examples.
