# Switchboard Chrome extension

This unpacked Manifest V3 extension controls explicitly leased website tabs through
`chrome.debugger`. It connects only to `local.daniil.switchboard.browser` using
Native Messaging. It does not use a debug port, TCP server, cookies permission,
content scripts, arbitrary caller JavaScript, arbitrary CDP methods, or local paths.

Stable unpacked ID: `hbhjeiejjmgpjhmmjifnpkdoeehojkmj`. The manifest's public key fixes
this ID across updates. No private signing key is included or required for unpacked
installation. A store identity is a separate migration and publication decision.

## Installation and pairing

Use Switchboard's Chrome setup to register its bundled native host and export the
extension directory. In regular Chrome, open `chrome://extensions`, enable Developer
mode, then choose **Load unpacked** and the exported directory. Open the extension
popup and enter its six-digit pairing code in Switchboard. Choose the intended Chrome by the name shown in the extension, then click
Connect this Chrome. If names match, give the intended Chrome a distinct name
in the extension and refresh the connection list. No browser restart or remote debugging setting
is required. Chrome owns its visible debugger indicator.

Each Chrome profile creates its own persistent random UUID in `storage.local`.
The app owns durable pairing; reconnects must prove possession of a locally stored
per-profile pairing secret. The secret never appears in popup state. A new native
connection must receive a fresh session
capability. The extension rejects incognito and non-HTTP(S) tabs.

## Version 1 wire contract

Native Messaging frames contain one JSON object. The fixed native host and
coordinator authenticate the local app and Chrome origin; a paired connection then
issues an opaque capability. Never log capabilities or page bodies.

Extension hello:

```json
{"type":"hello","version":1,"profileId":"uuid","profileName":"Chrome","pairingCode":"123456","pairingSecret":"only-after-pairing"}
```

Coordinator welcome (also sent on pairing confirmation):

```json
{"type":"welcome","version":1,"profileId":"uuid","paired":true,"sessionId":"opaque-id","capability":"opaque-token","pairingSecret":"new-profile-proof"}
```

The pairing welcome supplies `pairingSecret`, stored in extension-local storage and
presented only to the native host on reconnect. A profile UUID alone is insufficient.

Request:

```json
{"type":"request","id":"action-uuid","operation":"read","profileId":"uuid","chatId":"chat-uuid","sessionId":"opaque-id","capability":"opaque-token","leaseId":"lease-uuid","params":{}}
```

Every request requires `profileId`, `chatId`, `sessionId`, and `capability`. Open and
select also require an app-issued `leaseId`; tab operations match that lease's chat.
Responses use `{type:"response",id,result}` or
`{type:"response",id,error:{code,message}}`. Errors are machine-readable codes.

Operations and parameters:

- `status`, `list`: no tab lease. List returns only titles, URLs, IDs and leased state;
  it does not read page bodies. Output is bounded to 300 website tabs.
- `open`: `{url}`. Creates an inactive tab in the chat's Switchboard group.
- `select`: `{tabId,userSelected:true}`. Coordinator must verify the user's explicit
  request. Existing tabs stay in their original groups and remain open.
- `read`, `find`, `verify`: optional `{frameId,query}`; find requires nonempty query;
  read also takes `waitSeconds` (0.1-10, a pause before observing).
  Returns bounded page text, controls with `ref`, `documentToken`, URL, `alerts`
  (`role=alert`, `aria-live=assertive`) and frame IDs. Open shadow roots are walked.
  Controls carry form state: `value` (bounded; selected option labels, chosen file
  names), `checked`, `required`, `invalid`, `error` (`aria-errormessage` or the
  browser validation message) and `description` (`aria-describedby`); links carry
  `href`. Sensitive fields (password, hidden, one-time-code, `cc-*`) never report a
  value. Find ranks controls lexically over name, value, description, link address
  and role words (ru/en) and returns at most 50 with a `score`.
  Verify is a fresh observation for the caller to compare with its expected result.
- `screenshot`: JPEG of the main-frame viewport, longer side at most 1280 image pixels
  (device pixel ratio included). Response `{mimeType,base64,width,height,url,
  documentToken,viewport:{width,height}}`. The extension keeps the latest full
  screenshot's pixel mapping per tab for input by `x,y`. `clip:{x,y,width,height}` in
  pixels of that screenshot returns a zoomed region (`zoom`) at up to native
  resolution and keeps the mapping. Optional `waitSeconds` as for read.
  Rejects output over 700,000 base64 characters.
Pointer and key input select the leased tab before dispatch because Chrome can
acknowledge input to inactive tabs without delivering DOM events. The browser
window is not foregrounded, and no later action restores an earlier selected tab.
Reads and screenshots remain in the background.

- `input`: `{action,expectedURL,documentToken,frameId?,ref?|x,y,...}`. Arguments are
  validated before Chrome is touched.
  - `click`, `double_click`, `triple_click`, `right_click`: exactly one of `ref` and
    `x,y`. `x,y` are pixels of the latest full screenshot of the tab (no `frameId`);
    they are refused (`screenshot_stale`) when the document, URL, viewport size or
    scroll position changed since it. The element under the point is classified
    first, through same-origin frames and open shadow roots: sensitive fields and
    file inputs are refused (`file_input_use_upload`); a point in a frame the
    debugger cannot enter is clicked and reported `classified:false`.
  - `type`: `text` (1-5,000 characters). With `ref` it clicks and focuses the field;
    without it inserts into the focused element, which must be verifiable, editable
    and not sensitive.
  - `key`: a closed list (Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home,
    End, PageUp, PageDown, one printable ASCII character) with modifier chords
    (`cmd+a`, `shift+Tab`, `ctrl+c`), at `ref` or the focused element. A printable key
    without a ref follows the sensitive-field rule of type.
  - `scroll`: `deltaY`/`deltaX` (absolute maximum 5,000), at `ref`, at `x,y` or at the
    viewport centre. `scroll_to`: `ref`, scrolls it into view without a click.
  - `set_value`: `ref` plus `value` (label or value of a native select option) or
    `checked` (checkbox, switch or radio; clicked only when the state differs; a
    radio cannot be unchecked).
  - `dialog`: `accept` and optional `promptText`; requires an observed document and
    a matching JavaScript dialog event, and bypasses blocked page evaluation.
  Input by ref works in frames this tab's debugger can enter (same-process frames,
  `frameId` from read); positions are offset by the frame's box
  (`DOM.getFrameOwner`, `DOM.getBoxModel`). Frames in another process are refused
  with `frame_input_unsupported`.
- `upload`: `{expectedURL,documentToken,ref,files:[{name,mimeType,base64}]}`. The
  coordinator approves project paths and reads bytes. The extension accepts no
  paths; it sets a file input using bounded File/DataTransfer objects. At most ten
  files and 512 KiB decoded data combined. OS file pickers are outside the contract.
- `release`: `{close?:false}`. Detaches, revokes ownership, and preserves the tab.
  `close:true` is accepted only for tabs this extension created for that lease.

Authenticated revocation:

```json
{"type":"revoke","version":1,"profileId":"uuid","sessionId":"opaque-id","capability":"opaque-token","chatId":"chat-uuid","tabId":123,"leaseId":"lease-uuid"}
```

Popup Stop emits `{type:"event",event:"stop",version:1,profileId,chatId?,tabId?,leaseIds}`.
The coordinator must persist revocation and remove matching chat grants. Extension
Stop takes effect locally before notifying the app. Disconnect/detach drops leases;
no mutation is replayed. At most 1,000 recent mutation IDs are retained locally;
coordinator's durable action journal remains authoritative after local eviction.

## Boundaries and validation

Only fixed, packaged functions execute in a debugger-created isolated world.
Documents receive random tokens; refs resolve through WeakRefs in that world.
Mutation requires an exact observed URL and document token. Password, hidden,
one-time-code, and recognized payment inputs cannot be targeted by ref.
Screenshots can still contain user-visible sensitive information.

Stop cancels queued work and checks revocation before each debugger command. A
command Chrome already accepted may finish; Stop cannot undo a website submission.
Service-worker recovery reconnects transport only. Old requests are never retried.
User-owned tabs are never moved, closed, or restored from disk.

Cross-origin frames can be selected for reads when Chrome exposes their debugger
execution context. Out-of-process frames would need `Target.setAutoAttach` child
sessions (Chrome 125+); they are not attached, so input there needs coordinates.
Out-of-process frame coverage, JS dialogs, File/DataTransfer upload acceptance,
and real signed-in session behavior require the manual fixture acceptance gate;
mock tests do not establish browser compatibility. Closed shadow DOM, native
browser dialogs, CAPTCHA, passkeys, and browser-privileged pages are unsupported.

Run authority and lifecycle checks with `node --test UserChromeExtension/controller.test.js`.
No npm install or generated assets are needed. Production export includes runtime
files only: manifest, worker, controller, page, popup files, and both locale folders.
