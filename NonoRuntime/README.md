# Pinned nono helper

`runtime.lock.json` pins the official macOS arm64 nono release: archive URL and SHA256, extracted binary
SHA256, signing identifier and Apple Developer Team ID. `LICENSE` is the upstream Apache 2.0 license at
the pinned tag (the tagged tree has no NOTICE file). The helper keeps its upstream signature; the app
never re-signs it.

`scripts/build-app.sh` stages the binary into `Switchboard.app/Contents/Helpers/nono` and the lock and
license into `Contents/Resources/NonoRuntime` (codesign treats every file under Helpers as code) with

```sh
python3 scripts/prepare-nono.py /staging/Switchboard.app/Contents/Helpers --resources /staging/Switchboard.app/Contents/Resources/NonoRuntime
```

The packager downloads the archive once into `.build/nono-cache/` (or takes `--archive`), checks the
archive checksum, extracts only the `nono` member, checks the binary checksum, `lipo` architecture and
the vendor code signature with `codesign --verify --strict -R`, and copies the binary, the lock and the
license. There is no runtime download or update path: a new helper ships with a new Switchboard build
after the lock is updated by hand and the probes below pass. Intel is not covered by this pin.

The signature check needs the certificate chain, which a command sandbox cannot evaluate; run the
packager (and `build-app.sh`) outside one. `scripts/test-prepare-nono.py` covers the rejection paths.

## How the app uses it

`ExternalSandbox.swift` (ContextCore) verifies the staged helper again before each use (checksum,
Mach-O arm64, signature through the Security framework), compiles a per-worker policy from the role
profile and the project settings, and `CodexConnection` launches
`python3 -c setsid … nono run … -- codex app-server …` so the whole tree is one process group.
`SandboxRuntime/` carries app-owned MCP servers outside the boundary.

Probes (credential-free, run outside an enclosing sandbox; they create folders under `.build` and
`~/Library/Application Support/Switchboard-sandbox/`, and remove them):

```sh
python3 scripts/probe-nono-runtime.py --nono .build/nono/nono     # session union, Keychain and git mediation, Chrome host, SwiftPM, teardown, proxy
python3 scripts/probe-codex-nono.py --nono .build/nono/nono       # real Codex app-server: externalSandbox, zero approvals, MCP relay, denials
```
