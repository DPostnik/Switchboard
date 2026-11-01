# Build and run on macOS

This is a source preview. There is no downloadable DMG in this walkthrough.

## Prerequisites

| Dependency | Needed for |
| --- | --- |
| macOS, target 14 or later | Native SwiftUI/AppKit application; Apple Silicon is the tested architecture |
| Matching Swift 6 compiler and macOS SDK, from Xcode or Command Line Tools | Building; Swift Testing is also needed for the test suite |
| Python 3.10+ on PATH, Git, zsh | Build/test orchestration and source checkout |
| Internet access to GitHub | Resolving TOMLDecoder, exactly 0.4.5, from `Package.resolved` |
| Official Codex binary and account with Codex access | Using an agent; neither is needed to compile or run the offline tests |
| Node.js 22.12+, Google Chrome, `/usr/bin/python3` (tested: 3.9.6) | Optional browser adapter only |
| uv and Python 3.12 | Optional Headroom plugin only |

Install a complete, matching [Apple toolchain](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools). Do not mix SDKs and compilers from different installations. This project does not install or switch your toolchain.

```sh
git clone https://github.com/DPostnik/Switchboard.git
cd Switchboard
python3 --version
xcode-select -p
xcrun swift --version
xcrun swift package --version
zsh scripts/build-app.sh
zsh scripts/test.sh
open 'build/Switchboard.app'
```

The scripts probe Foundation, SwiftUI and AppKit, resolve the locked dependency, build the executable, generate the app icon, assemble the bundle and verify its ad-hoc signature. `build/Switchboard.app/Contents/Resources/build-info.json` records compiler, SDK, backend and source digest. It contains a machine-specific SDK path; it is a local diagnostic, not a public attachment.

The build stages the complete bundle before replacing the previous workspace app. If it fails, the previous bundle is still the old build. No script restarts your running app. After a successful rebuild, quit with **Cmd+Q** and reopen the new bundle when your work is finished. Closing a window alone does not quit.

## First agent session

1. Install [Codex CLI](https://learn.chatgpt.com/docs/codex/cli), or use a supported official ChatGPT/Codex desktop installation. Verify its reported version. The locally tested binary reports `codex-cli 0.158.0-alpha.2.1`; archive summaries explicitly require that version.
2. Start Switchboard. The initial interface may be Russian. Use the settings gear → **Язык / Language** → **English**, then Cmd+Q and reopen.
3. Choose **Open Project…** (Cmd+O) and select the copied [code exercise](examples.md). Keep **Ask for approval** and **No plugin** for the first run.
4. Choose **Sign in** and complete ChatGPT authentication. Switchboard uses its own Codex home; signing into another Codex client does not transfer credentials here.
5. Select an available model and send the example prompt. Review command or filesystem approval requests as they appear. Network/account failures are not a reason to resend a request whose outcome is uncertain.

Discovery checks official app bundles under `/Applications` and `~/Applications` (including nested `CodexCLI.app`), then `/opt/homebrew/bin`, `/usr/local/bin` and absolute PATH entries. A GUI launch may have a different PATH from your terminal. If your CLI is only in a shell version manager, launch the built executable from that terminal to diagnose discovery:

```sh
'build/Switchboard.app/Contents/MacOS/Switchboard'
```

Quit the existing instance first yourself; do not run duplicate owners against the same private app home. Recheck compatibility after upgrading Codex. Its App Server is the integration boundary; [official App Server documentation](https://learn.chatgpt.com/docs/app-server) describes that protocol.

## Optional browser setup

```sh
node --version
python3 BrowserRuntime/install.py
```

If Node is not on PATH, pass `--node /absolute/path/to/node`. The installer verifies the pinned Chrome DevTools MCP 1.10.1 archive and extracted files; it does not run npm install scripts. The application launches the adapter with `/usr/bin/python3`; check that interpreter as well (`/usr/bin/python3 --version`). Then enable **Settings → Browser → Use Chrome DevTools**; Codex reconnects to apply it once chats are idle. See the [browser contract](../BrowserRuntime/README.md).

Chrome uses a separate profile; no login is needed for the included loopback fixture. Run the server only while demonstrating the example. An agent can ask for permissions depending on project policy. Stop a blocked run and review the request instead of changing the project to Full access to make the demo pass.

## Troubleshooting and validation scope

- **SDK or Swift Testing error:** use a matching Xcode/CLT installation. Inspect `.build/local-build/sdk-probe-error.log` or `testing-probe-error.log` locally. `SWITCHBOARD_SDK` can select an already installed compatible SDK; it does not repair a mismatched toolchain.
- **Dependency download fails:** check GitHub connectivity. The direct-compiler fallback requires an existing clean TOMLDecoder checkout at the locked revision, so it cannot bootstrap a fresh checkout offline.
- **Compiler/test failure:** report the exact failure. The scripts do not hide a real compilation failure behind the fallback.
- **Codex missing or sign-in unavailable:** check discovery/version separately from build success. Do not copy `auth.json` from another client.
- **Browser runtime unavailable:** check Chrome installation, Node version and runtime installation. Reapply settings only when work is idle. Do not retry an uncertain action automatically.

No Apple Developer Program membership is required for this local ad-hoc build. Developer ID signing and notarization are separate distribution work. A DMG is not a prerequisite for trying the source.

[Actual checks](validation.md) were made on the author's current Mac. A fresh source directory on the same Mac still shares its installed tools and dependency caches; it is **not a clean-Mac test**.
