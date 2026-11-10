# User Chrome runtime

Python 3.9+ standard library only. This transport never opens TCP, launches Chrome,
imports sessions, reads browser profiles, or forwards caller-supplied CDP commands.
`server.py` is bundled with the app. The app owns setup, authorization and lifecycle.

## Installation contract

The app creates a private `0700` state directory and a random `0600` regular file
`control-token` containing at least 32 random bytes encoded as text. It exports the
extension with its stable public manifest key to an app-support directory and
registers `local.daniil.switchboard.browser` under the current user's Google Chrome
NativeMessagingHosts directory. The manifest's `allowed_origins` contains exactly
`chrome-extension://hbhjeiejjmgpjhmmjifnpkdoeehojkmj/`.

The manifest points to an executable shell launcher with fixed, shell-quoted paths:

```sh
#!/bin/sh
exec /usr/bin/python3 -B '/absolute/app-support/runtime/server.py' native --state-dir '/absolute/private/state' --extension-id hbhjeiejjmgpjhmmjifnpkdoeehojkmj "$@"
```

Use an available verified Python executable. The app must surface missing Python as
a setup error. Chrome adds the extension origin argument; native validates it exactly.
Only the user's explicit Load unpacked installation is supported initially.

Start exactly one coordinator per state directory:

```sh
python3 -B server.py serve --state-dir STATE --extension-id EXTENSION_ID
python3 -B server.py status --state-dir STATE
python3 -B server.py pair --state-dir STATE --control-token-file STATE/control-token --profile-id PROFILE --code 123456
python3 -B server.py set-enabled --state-dir STATE --control-token-file STATE/control-token --enabled true
python3 -B server.py grant --state-dir STATE --control-token-file STATE/control-token --chat-id CHAT --project-root PROJECT
python3 -B server.py revoke --state-dir STATE --control-token-file STATE/control-token --chat-id CHAT
python3 -B server.py select-profile --state-dir STATE --control-token-file STATE/control-token --profile-id PROFILE
python3 -B server.py shutdown-if-idle --state-dir STATE --control-token-file STATE/control-token
```

`grant` optionally accepts `--profile-id`; otherwise it uses the last explicitly
paired profile. Its private stdout JSON contains `capability`, `chatId`, `profileId`,
`projectRoot`, `expiresAt`. The app saves only the capability to a private `0600`
regular file, then starts the per-chat adapter:

```sh
python3 -I server.py mcp --state-dir STATE --chat-id CHAT --profile-id PROFILE --capability-file PRIVATE_FILE
```

Do not put either secret in command arguments or logs. Grant renewal retains an
unexpired token for the same chat/profile/project. Revocation removes it permanently;
issuance after revocation creates a new token. The app must revoke on effective role
permission removal and disable globally with `set-enabled --enabled false`.
The adapter cannot mint grants; its fixed chat/profile/capability applies to every call.

`select-profile` changes the default only to an already paired profile. Existing
grants remain associated with their explicit profile; issuing a replacement grant
for another profile/project revokes the old grant and tab leases first.

`shutdown-if-idle` rejects active leases or in-flight actions with `coordinator_busy`.
It marks shutdown before accepting further actions, acknowledges `shuttingDown:true`,
then exits and removes its socket within 250 ms. Before replacing runtime files,
the installer must receive that acknowledgement and verify socket disappearance.
Never retry a shutdown with an uncertain outcome; inspect status first.

`status` is a bounded metadata snapshot with wire `version`, `runtimeRevision` (3),
`shuttingDown`, `enabled`, `selectedProfileId`,
`profiles` (`id`, `name`, `connected`, `paired`; compatibility `profileId`/`profileName`),
and active leases. It never includes pairing or capability secrets.

## Wire protocol v1

All native/socket frames are four-byte little-endian unsigned length plus UTF-8
JSON object, maximum 900000 bytes. Empty, oversized, truncated and non-object frames
fail closed. Socket permissions are `0600`; parent directory is `0700`; Unix peer UID
must match the current user. A lock prevents a second coordinator from replacing a
live socket. No generic shell or generic debugging endpoint exists.

The extension sends `hello` with `version:1`, persistent `profileId`, `profileName`,
a six-digit `pairingCode`, and, after pairing, persistent `pairingSecret`. The native
helper wraps this as `{type:"native",origin,hello}`. The app pairs by matching the
extension-displayed code. Pairing generates a random per-profile reconnect secret,
stored only in private app state and extension local storage. A paired UUID alone
never authenticates a reconnect. `welcome` contains `version`, `profileId`, `paired`,
`sessionId`, fresh session `capability`, and (only when authenticated/just paired)
`pairingSecret`. Pairing sends another welcome over the existing connection.

Coordinator requests contain `type:"request"`, `version:1`, `id`, `operation`,
`profileId`, `chatId`, `sessionId`, session `capability`, `leaseId`, `params`.
The extension never receives the app's chat grant or control token. Responses are
`{type:"response",id,result}` or `{type:"response",id,error:{code,message}}`.

Operations are status/list/select/open/read/find/screenshot/input/verify/upload/release.
Open/select receive an app-issued lease ID and return `tabId`. Explicit existing-tab
selection requires `userSelected:true`. Every other tab operation checks the durable
(profile, tab, chat) lease. Input/upload require the last observation's exact URL and
document token in the extension. The extension exposes fixed bounded commands only.
Upload resolves project-approved paths, walks components with no-follow file handles,
checks regular files and sends bounded bytes, never a local path, to the extension.
Combined upload bytes are at most 512000; JPEG screenshots at most 700000 base64 bytes.

Stop events `{type:"event",event:"stop",profileId,chatId?,tabId?}` revoke grants/leases.
Host revocation messages include authenticated session/profile, chat and optional tab.
The extension immediately invalidates queued work and detaches only its debugger.
An action already executed cannot be undone. Existing tabs stay open unless an
explicit close targets an agent-created tab.

The SQLite action journal stores only action ID, chat, operation and dispatch state.
Dispatch is committed before sending. Duplicate IDs are always rejected. Disconnect,
timeout or coordinator restart leaves `unknown`, never automatic replay. Observe the
page before a new action. No page bodies, response payloads or upload bytes are logged.

## Validation and limits

```sh
python3 -B -m unittest discover -s UserChromeRuntime -p 'test_transport.py'
```

Tests use temporary private state and a fake native connection, never user Chrome.
Real installed-extension, debugger upload, dialogs, cross-origin frame, signed-in
page and Codex discovery verification remain separate acceptance gates. Local tests
do not prove those gates. The Python helper is not a separately compiled signed
native executable; the app packaging signs its containing resources/launcher.
