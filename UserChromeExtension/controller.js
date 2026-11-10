import {observePage, resolveElement, installUpload} from './page.js';

export const HOST = 'local.daniil.switchboard.browser';
export const VERSION = 1;
const MUTATIONS = new Set(['open', 'select', 'input', 'upload', 'release']);
const OPERATIONS = new Set(['status', 'list', 'open', 'select', 'read', 'find', 'screenshot', 'input', 'verify', 'upload', 'release']);
const MAX_FRAME = 900000;
const fail = (code, message = code) => Object.assign(new Error(message), {code});
const identifier = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,160}$/.test(value);
export const websiteURL = value => { try { return ['http:', 'https:'].includes(new URL(value).protocol); } catch { return false; } };

export class Controller {
  constructor(chrome, {operationTimeoutMs = 30000} = {}) {
    this.chrome = chrome;
    this.session = null;
    this.leases = new Map();
    this.attached = new Set();
    this.groups = new Map();
    this.documents = new Map();
    this.dialogs = new Map();
    this.dialogWaiters = new Map();
    this.generation = 0;
    this.queue = Promise.resolve();
    this.pending = 0;
    this.journal = {};
    this.stopped = new Set();
    this.error = null;
    this.operationTimeoutMs = operationTimeoutMs;
    this.quarantined = false;
  }
  async initialize() {
    const stored = await this.chrome.storage.local.get(['profileId', 'profileName', 'pairingSecret', 'journal']);
    this.profileId = stored.profileId || crypto.randomUUID();
    this.profileName = stored.profileName || 'Chrome';
    this.pairingSecret = stored.pairingSecret || null;
    // Codes never persist. A restarted worker requires a fresh code for an unpaired profile.
    this.pairingCode = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, '0');
    this.journal = stored.journal || {};
    await this.chrome.storage.local.set({profileId: this.profileId, profileName: this.profileName});
  }
  hello() { return {type: 'hello', version: VERSION, profileId: this.profileId, profileName: this.profileName, pairingCode: this.pairingCode, ...(this.pairingSecret ? {pairingSecret: this.pairingSecret} : {})}; }
  async welcome(message) {
    if (this.quarantined) throw fail('previous_operation_still_pending');
    if (message.version !== VERSION || message.profileId !== this.profileId) throw fail('protocol_mismatch');
    await this.revoke(undefined, undefined, false);
    if (message.paired === true && identifier(message.pairingSecret)) {
      this.pairingSecret = message.pairingSecret;
      await this.chrome.storage.local.set({pairingSecret: this.pairingSecret});
    }
    this.session = message.paired === true && identifier(message.sessionId) && identifier(message.capability)
      ? {sessionId: message.sessionId, capability: message.capability} : null;
    this.error = null;
  }
  status() {
    return {profileId: this.profileId, profileName: this.profileName, pairingCode: this.session ? null : this.pairingCode,
      paired: !!this.session, connected: !!this.port, error: this.error,
      leases: [...this.leases.values()].map(({leaseId, chatId, tabId, created}) => ({leaseId, chatId, tabId, created}))};
  }
  async connect() {
    if (this.quarantined) { this.error = 'previous_operation_still_pending'; return; }
    if (this.port) return;
    try {
      const port = this.chrome.runtime.connectNative(HOST);
      this.port = port;
      port.onMessage.addListener(message => this.receive(message));
      port.onDisconnect.addListener(() => {
        if (this.port !== port) return;
        this.error = this.chrome.runtime.lastError?.message || 'native_disconnected';
        this.port = null; this.session = null;
        void this.revoke();
        // Reconnection only re-establishes transport. No request or mutation is retried.
        void this.chrome.alarms.create('reconnect', {delayInMinutes: 0.5});
      });
      port.postMessage(this.hello());
    } catch (error) { this.error = error.message; this.port = null; }
  }
  send(message) {
    if (JSON.stringify(message).length > MAX_FRAME) throw fail('message_too_large');
    this.port?.postMessage(message);
  }
  receive(message) {
    if (!message || typeof message !== 'object') return;
    if (message.type === 'welcome') {
      // Queue negotiation with requests, so old queued work cannot see new authority.
      this.generation++;
      this.queue = this.queue.then(() => this.welcome(message)).catch(error => { this.error = error.code || error.message; });
    } else if (message.type === 'request') {
      if (this.pending >= 32 || JSON.stringify(message).length > MAX_FRAME) {
        if (this.authenticated(message) && identifier(message.id)) this.send({type: 'response', id: message.id, error: {code: 'queue_full', message: 'queue_full'}});
        return;
      }
      this.pending++;
      const generation = this.generation;
      this.queue = this.queue.then(async () => {
        let reply;
        try {
          if (generation !== this.generation) throw fail('revoked');
          reply = {type: 'response', id: message.id, result: await this.boundedDispatch(message, generation)};
        } catch (error) {
          reply = {type: 'response', id: message.id, error: {code: error.code || 'operation_failed', message: error.message}};
        }
        this.pending--;
        try { this.send(reply); } catch { /* Lost response remains in journal; never replay. */ }
        if (reply.error?.code === 'operation_timeout_unknown_outcome') {
          // Deliver the explicit failure first, then release the coordinator's pending requests. Reconnection must
          // remain manual and impossible until the original Chrome call settles; it cannot be cancelled safely.
          const port = this.port;
          this.port = null;
          try { port?.disconnect(); } catch {}
        }
      });
    } else if (message.type === 'revoke') {
      if (this.authenticated(message)) void this.revoke(message.chatId, message.tabId);
    }
  }
  authenticated(request) {
    return !!this.session && request.profileId === this.profileId && request.sessionId === this.session.sessionId && request.capability === this.session.capability;
  }
  assertLive(generation, lease) {
    if (generation !== this.generation || !this.session || (lease && this.leases.get(lease.leaseId) !== lease)) throw fail('revoked');
  }
  async boundedDispatch(request, generation = this.generation) {
    if (this.quarantined) throw fail('previous_operation_still_pending');
    let timeout;
    const operation = this.dispatch(request, generation);
    try {
      return await Promise.race([operation, new Promise((_, reject) => {
        timeout = setTimeout(() => {
          this.quarantined = true;
          this.generation++;
          this.session = null;
          this.error = 'operation_timeout_unknown_outcome';
          const cleanup = this.revoke(undefined, undefined, false);
          // Cleanup may itself await a Chrome callback. Neither late completion restores session authority.
          void Promise.allSettled([operation, cleanup]).then(() => { this.quarantined = false; });
          reject(fail('operation_timeout_unknown_outcome'));
        }, this.operationTimeoutMs);
      })]);
    } finally { clearTimeout(timeout); }
  }
  async revoke(chatId, tabId, invalidate = true) {
    if (invalidate) this.generation++;
    const leases = [...this.leases.values()].filter(lease => (!chatId || lease.chatId === chatId) && (!tabId || lease.tabId === tabId));
    for (const lease of leases) {
      this.leases.delete(lease.leaseId); this.stopped.add(lease.leaseId); this.documents.delete(lease.tabId); this.dialogs.delete(lease.tabId);
    }
    for (const lease of leases) {
      if (this.attached.delete(lease.tabId)) {
        try { await this.chrome.debugger.detach({tabId: lease.tabId}); } catch { /* Already detached. */ }
      }
    }
    // Empty groups may remain in Chrome; unrelated and borrowed tabs stay open.
  }
  async stop(chatId, tabId) {
    const leaseIds = [...this.leases.values()].filter(x => (!chatId || x.chatId === chatId) && (!tabId || x.tabId === tabId)).map(x => x.leaseId);
    await this.revoke(chatId, tabId);
    this.send({type: 'event', event: 'stop', version: VERSION, profileId: this.profileId, chatId, tabId, leaseIds});
    return this.status();
  }
  onDebuggerEvent(source, method, params = {}) {
    const tabId = source.tabId;
    if (!tabId) return;
    if (method === 'Page.frameNavigated' && !params.frame?.parentId) { this.documents.delete(tabId); this.dialogs.delete(tabId); }
    if (method === 'Page.javascriptDialogOpening') {
      this.dialogs.set(tabId, {url: params.url, documentToken: this.documents.get(tabId)});
      this.dialogWaiters.get(tabId)?.();
    }
    if (method === 'Page.javascriptDialogClosed') this.dialogs.delete(tabId);
  }
  async detach(tabId) {
    // onRemoved covers every Chrome tab; internal detach callbacks arrive after revoke removed their lease.
    // Neither event grants authority to invalidate unrelated chats or to disconnect the native protocol.
    if (![...this.leases.values()].some(lease => lease.tabId === tabId)) return;
    await this.revoke(undefined, tabId);
    this.send({type: 'event', event: 'detached', profileId: this.profileId, tabId});
  }
  async remember(id, state, operation) {
    this.journal[id] = {state, operation, at: Date.now()};
    // Entries are bounded. Old actions cannot replay: coordinator retains its durable action journal.
    const entries = Object.entries(this.journal).sort((a, b) => b[1].at - a[1].at).slice(0, 1000);
    this.journal = Object.fromEntries(entries);
    await this.chrome.storage.local.set({journal: this.journal});
  }
  async dispatch(request, generation = this.generation) {
    if (!this.authenticated(request)) throw fail('unauthorized');
    if (JSON.stringify(request).length > MAX_FRAME || !identifier(request.id) || !identifier(request.chatId) || !OPERATIONS.has(request.operation)) throw fail('invalid_request');
    const mutation = MUTATIONS.has(request.operation);
    if (mutation && this.journal[request.id]) throw fail('outcome_unknown', this.chrome.i18n?.getMessage('outcomeUnknown') || 'outcome_unknown');
    const p = request.params || {};
    if (!p || typeof p !== 'object' || Array.isArray(p)) throw fail('invalid_params');
    if (mutation) await this.remember(request.id, 'dispatched', request.operation);
    this.assertLive(generation);
    let result;
    if (request.operation === 'status') result = this.status();
    else if (request.operation === 'list') {
      const tabs = await this.chrome.tabs.query({});
      result = {tabs: tabs.filter(x => !x.incognito && websiteURL(x.url)).slice(0, 300).map(x => ({tabId: x.id, title: x.title?.slice(0, 500), url: x.url?.slice(0, 8192), leased: [...this.leases.values()].some(l => l.tabId === x.id)}))};
    } else if (['open', 'select'].includes(request.operation)) result = await this.acquire(request, generation);
    else {
      const lease = this.leases.get(request.leaseId);
      if (!lease || lease.chatId !== request.chatId) throw fail('lease_required');
      this.assertLive(generation, lease);
      if (request.operation === 'release') {
        if (p.close === true && !lease.created) throw fail('existing_tab_preserved');
        await this.revoke(lease.chatId, lease.tabId, false);
        this.assertLive(generation);
        if (p.close === true) await this.chrome.tabs.remove(lease.tabId);
        result = {released: true, closed: p.close === true};
      } else result = await this.operate(request, lease, generation);
    }
    this.assertLive(generation);
    if (mutation) await this.remember(request.id, 'completed', request.operation);
    return result;
  }
  async acquire(request, generation) {
    const p = request.params;
    if (!identifier(request.leaseId) || this.stopped.has(request.leaseId)) throw fail('invalid_lease');
    if (this.leases.has(request.leaseId)) throw fail('lease_exists');
    const created = request.operation === 'open';
    if (created ? !websiteURL(p.url) : (!Number.isInteger(p.tabId) || p.userSelected !== true)) throw fail('explicit_tab_selection_required');
    // Chrome removes a group when its last tab closes. Verify the cached group before
    // creating a tab; a failed lookup must not turn into a mutation or a blind retry.
    let groupId = created ? this.groups.get(request.chatId) : undefined;
    if (groupId !== undefined) {
      const groups = await this.chrome.tabGroups.query({});
      this.assertLive(generation);
      if (!groups.some(group => group.id === groupId)) {
        this.groups.delete(request.chatId);
        groupId = undefined;
      }
    }
    let tab;
    if (created) tab = await this.chrome.tabs.create({url: p.url, active: false});
    else tab = await this.chrome.tabs.get(p.tabId);
    this.assertLive(generation);
    if (tab.incognito || !websiteURL(tab.url || p.url)) throw fail('unsupported_page');
    if ([...this.leases.values()].some(lease => lease.tabId === tab.id)) throw fail('tab_busy');
    const lease = {leaseId: request.leaseId, chatId: request.chatId, tabId: tab.id, created};
    this.leases.set(lease.leaseId, lease);
    // Existing user tabs are never moved into agent groups.
    if (created) {
      try {
        groupId = await this.chrome.tabs.group({tabIds: [tab.id], ...(groupId === undefined ? {} : {groupId})});
        this.groups.set(request.chatId, groupId);
        await this.chrome.tabGroups.update(groupId, {title: `Switchboard ${request.chatId.slice(0, 8)}`, color: 'blue'});
      } catch (error) {
        await this.revoke(request.chatId, tab.id);
        throw fail('tab_group_failed', error.message);
      }
    }
    this.assertLive(generation, lease);
    return {tabId: tab.id, leaseId: lease.leaseId, url: tab.url || p.url, created};
  }
  async command(lease, generation, method, params = {}) {
    this.assertLive(generation, lease);
    return this.chrome.debugger.sendCommand({tabId: lease.tabId}, method, params);
  }
  // Chrome can leave an input command pending until its JavaScript dialog is handled.
  // Return the observed dialog to the caller so the next authorized request can handle it.
  // The original command is never replayed; its eventual rejection remains consumed.
  async inputCommand(lease, generation, method, params) {
    let opened;
    const dialog = new Promise(resolve => { opened = () => resolve(true); });
    this.dialogWaiters.set(lease.tabId, opened);
    try {
      const pending = await Promise.race([
        this.command(lease, generation, method, params).then(() => false), dialog
      ]);
      this.assertLive(generation, lease);
      return pending;
    } finally {
      if (this.dialogWaiters.get(lease.tabId) === opened) this.dialogWaiters.delete(lease.tabId);
    }
  }
  async attach(lease, generation) {
    if (this.attached.has(lease.tabId)) return;
    this.assertLive(generation, lease);
    try { await this.chrome.debugger.attach({tabId: lease.tabId}, '1.3'); }
    catch (error) { throw fail('debugger_conflict', error.message); }
    try { this.assertLive(generation, lease); }
    catch (error) {
      try { await this.chrome.debugger.detach({tabId: lease.tabId}); } catch {}
      throw error;
    }
    this.attached.add(lease.tabId);
    await this.command(lease, generation, 'Page.enable');
  }
  async world(lease, generation, frameId) {
    const tree = await this.command(lease, generation, 'Page.getFrameTree');
    const frames = [];
    const visit = (node, depth) => {
      if (depth > 3 || frames.length >= 50) return;
      frames.push({frameId: node.frame.id, url: node.frame.url, name: node.frame.name || '', main: depth === 0});
      for (const child of node.childFrames || []) visit(child, depth + 1);
    };
    visit(tree.frameTree, 0);
    const frame = frameId ? frames.find(x => x.frameId === frameId) : frames[0];
    if (!frame || !websiteURL(frame.url)) throw fail('unsupported_frame');
    const world = await this.command(lease, generation, 'Page.createIsolatedWorld', {frameId: frame.frameId, worldName: 'Switchboard bounded tools v1'});
    return {contextId: world.executionContextId, frame, frames};
  }
  async evaluate(lease, generation, contextId, fn, args) {
    const result = await this.command(lease, generation, 'Runtime.evaluate', {
      contextId, expression: `(${fn.toString()})(${JSON.stringify(args)})`, returnByValue: true, awaitPromise: false, timeout: 3000});
    if (result.exceptionDetails) throw fail('page_operation_failed', result.exceptionDetails.exception?.description?.slice(0, 500) || result.exceptionDetails.text);
    return result.result?.value;
  }
  async operate(request, lease, generation) {
    const p = request.params;
    const tab = await this.chrome.tabs.get(lease.tabId);
    if (!websiteURL(tab.url)) throw fail('unsupported_page');
    if (p.expectedURL && p.expectedURL !== tab.url) throw fail('stale_navigation');
    const isMutation = ['input', 'upload'].includes(request.operation);
    if (isMutation && (!p.expectedURL || !identifier(p.documentToken))) throw fail('observation_required');
    await this.attach(lease, generation);
    if (request.operation === 'input' && p.action === 'dialog') {
      const dialog = this.dialogs.get(lease.tabId);
      if (!dialog || dialog.documentToken !== p.documentToken || dialog.url !== p.expectedURL) throw fail('dialog_observation_required');
      if (typeof p.accept !== 'boolean' || (p.promptText && (typeof p.promptText !== 'string' || p.promptText.length > 5000))) throw fail('invalid_dialog');
      await this.command(lease, generation, 'Page.handleJavaScriptDialog', {accept: p.accept, promptText: p.promptText || ''});
      return {handled: true};
    }
    const world = await this.world(lease, generation, p.frameId);
    if (['read', 'find', 'verify'].includes(request.operation)) {
      if (request.operation === 'find' && (typeof p.query !== 'string' || !p.query.trim() || p.query.length > 500)) throw fail('query_required');
      const result = await this.evaluate(lease, generation, world.contextId, observePage, {query: p.query});
      this.documents.set(lease.tabId, result.documentToken);
      return {...result, tabId: lease.tabId, frameId: world.frame.frameId, frames: world.frames};
    }
    if (request.operation === 'screenshot') {
      const metrics = await this.command(lease, generation, 'Page.getLayoutMetrics');
      const viewport = metrics.cssVisualViewport || metrics.visualViewport;
      const scale = Math.min(1, 1280 / Math.max(viewport.clientWidth, viewport.clientHeight));
      const result = await this.command(lease, generation, 'Page.captureScreenshot', {format: 'jpeg', quality: 60,
        captureBeyondViewport: false, clip: {x: viewport.pageX, y: viewport.pageY, width: viewport.clientWidth, height: viewport.clientHeight, scale}});
      if (result.data.length > 700000) throw fail('screenshot_too_large');
      return {mimeType: 'image/jpeg', base64: result.data};
    }
    // Check the actual observed document in the isolated world immediately before every input.
    const current = await this.evaluate(lease, generation, world.contextId, observePage, {});
    if (current.documentToken !== p.documentToken) throw fail('stale_document');
    if (p.expectedURL !== tab.url) throw fail('stale_navigation');
    if (request.operation === 'upload') {
      validateFiles(p.files);
      return this.evaluate(lease, generation, world.contextId, installUpload, {ref: p.ref, documentToken: p.documentToken, files: p.files});
    }
    if (request.operation !== 'input') throw fail('unsupported_operation');
    if (!['click', 'type', 'key', 'scroll'].includes(p.action)) throw fail('unsupported_input');
    if (p.action === 'type' && (typeof p.text !== 'string' || p.text.length > 5000)) throw fail('text_too_large');
    if (!world.frame.main) throw fail('frame_input_unsupported', this.chrome.i18n?.getMessage('frameInputUnsupported') || 'frame_input_unsupported');
    // Chrome acknowledges pointer/key dispatch to inactive tabs without delivering DOM events.
    // Select only this authorized lease; never foreground the browser window or switch back later.
    if (!tab.active) {
      await this.chrome.tabs.update(lease.tabId, {active: true});
      this.assertLive(generation, lease);
    }
    let point;
    if (['click', 'type'].includes(p.action)) {
      if (!/^ref_\d{1,9}$/.test(p.ref || '')) throw fail('ref_required');
      point = await this.evaluate(lease, generation, world.contextId, resolveElement, {ref: p.ref, documentToken: p.documentToken});
      if (await this.inputCommand(lease, generation, 'Input.dispatchMouseEvent', {type: 'mousePressed', button: 'left', clickCount: 1, ...point})) return {dialogPending: true, observationRequired: true};
      if (await this.inputCommand(lease, generation, 'Input.dispatchMouseEvent', {type: 'mouseReleased', button: 'left', clickCount: 1, ...point})) return {dialogPending: true, observationRequired: true};
      if (p.action === 'type') {
        const afterClick = await this.evaluate(lease, generation, world.contextId, observePage, {});
        if (afterClick.documentToken !== p.documentToken || afterClick.url !== world.frame.url) throw fail('stale_document');
        await this.evaluate(lease, generation, world.contextId, resolveElement, {ref: p.ref, documentToken: p.documentToken, focus: true});
        if (await this.inputCommand(lease, generation, 'Input.insertText', {text: p.text})) return {dialogPending: true, observationRequired: true};
      }
    } else if (p.action === 'key') {
      if (!/^ref_\d{1,9}$/.test(p.ref || '')) throw fail('ref_required');
      await this.evaluate(lease, generation, world.contextId, resolveElement, {ref: p.ref, documentToken: p.documentToken, focus: true});
      const keys = {Enter: 13, Tab: 9, Escape: 27, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39};
      if (!Object.hasOwn(keys, p.key)) throw fail('unsupported_key');
      if (await this.inputCommand(lease, generation, 'Input.dispatchKeyEvent', {type: 'keyDown', key: p.key, code: p.key, windowsVirtualKeyCode: keys[p.key]})) return {dialogPending: true, observationRequired: true};
      if (await this.inputCommand(lease, generation, 'Input.dispatchKeyEvent', {type: 'keyUp', key: p.key, code: p.key, windowsVirtualKeyCode: keys[p.key]})) return {dialogPending: true, observationRequired: true};
    } else {
      if (![p.deltaX || 0, p.deltaY].every(v => Number.isFinite(v) && Math.abs(v) <= 2000)) throw fail('invalid_scroll');
      if (await this.inputCommand(lease, generation, 'Input.dispatchMouseEvent', {type: 'mouseWheel', x: 10, y: 10, deltaX: p.deltaX || 0, deltaY: p.deltaY})) return {dialogPending: true, observationRequired: true};
    }
    return {performed: p.action, observationRequired: true};
  }
}

export function validateFiles(files) {
  if (!Array.isArray(files) || files.length < 1 || files.length > 10) throw fail('invalid_files');
  let bytes = 0;
  for (const file of files) {
    if (!file || typeof file.name !== 'string' || !file.name.length || file.name.length > 255 || /[\/\\\x00]/.test(file.name) ||
        typeof file.mimeType !== 'string' || file.mimeType.length > 150 || typeof file.base64 !== 'string' ||
        file.base64.length > 700000 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(file.base64)) throw fail('invalid_file');
    bytes += file.base64.length / 4 * 3 - (file.base64.endsWith('==') ? 2 : file.base64.endsWith('=') ? 1 : 0);
  }
  if (bytes > 512 * 1024) throw fail('upload_too_large');
}
