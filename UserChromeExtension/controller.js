import {observePage, pageInfo, resolveElement, inspectPoint, inspectFocus, selectOption, installUpload, renderTabOverlay} from './page.js';

export const HOST = 'local.daniil.switchboard.browser';
export const VERSION = 1;
// Feature revision of the extension's operations within wire version 1. The coordinator rejects
// arguments newer than the connected extension with a reload hint instead of a vague failure.
export const REVISION = 3;
const INPUT_ACTIONS = new Set(['click', 'double_click', 'triple_click', 'right_click', 'type', 'key', 'scroll', 'scroll_to', 'set_value', 'dialog']);
const POINTER = {click: ['left', 1], double_click: ['left', 2], triple_click: ['left', 3], right_click: ['right', 1]};
const MAX_IMAGE_SIDE = 1280;
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
    this.attaching = new Map();
    this.detaching = new Map();
    this.groups = new Map();
    this.documents = new Map();
    this.dialogs = new Map();
    this.dialogWaiters = new Map();
    // Per tab: pixel mapping of the latest full screenshot, for input by x,y.
    this.shots = new Map();
    // Global epoch: reconnection, a full stop or an expired operation invalidates everything in flight.
    this.generation = 0;
    // Per-chat epochs: revoking one chat cancels only that chat's in-flight work. A single tab's
    // revocation needs no epoch; removing its lease already fails every operation on that tab.
    this.chatEpochs = new Map();
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
  hello() { return {type: 'hello', version: VERSION, revision: REVISION, profileId: this.profileId, profileName: this.profileName, pairingCode: this.pairingCode, ...(this.pairingSecret ? {pairingSecret: this.pairingSecret} : {})}; }
  async welcome(message) {
    if (this.quarantined) throw fail('previous_operation_still_pending');
    if (message.version !== VERSION || message.profileId !== this.profileId) throw fail('protocol_mismatch');
    await this.revoke(undefined, undefined, false);
    if (message.paired === true && identifier(message.pairingSecret)) {
      this.pairingSecret = message.pairingSecret;
      await this.chrome.storage.local.set({pairingSecret: this.pairingSecret});
    }
    this.session = message.paired === true && identifier(message.sessionId) && identifier(message.capability)
      ? {sessionId: message.sessionId, capability: message.capability, runtimeRevision: message.runtimeRevision || 1} : null;
    this.error = null;
  }
  status() {
    return {profileId: this.profileId, profileName: this.profileName, pairingCode: this.session ? null : this.pairingCode,
      paired: !!this.session, connected: !!this.port, error: this.error,
      leases: [...this.leases.values()].map(({leaseId, chatId, tabId, created, title}) => ({leaseId, chatId, tabId, created, title}))};
  }
  async rename(name) {
    this.profileName = name.trim() || 'Chrome';
    await this.chrome.storage.local.set({profileName: this.profileName});
    // Metadata only: preserve the connection, grants and active tab leases.
    this.send({type: 'event', event: 'profileRenamed', profileName: this.profileName});
    return this.status();
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
      const live = this.liveToken(message);
      this.queue = this.queue.then(async () => {
        let reply;
        try {
          if (!this.isLive(live)) throw fail('revoked');
          reply = {type: 'response', id: message.id, result: await this.boundedDispatch(message, live)};
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
    } else if (message.type === 'release-lease') {
      if (this.authenticated(message) && identifier(message.id)) void this.releaseFromApp(message);
    } else if (message.type === 'revoke' && this.authenticated(message)) {
      if (message.leaseId) {
        const lease = this.leases.get(message.leaseId);
        if (lease && lease.chatId === message.chatId && lease.tabId === message.tabId) void this.dropLease(lease);
      } else {
        void this.revoke(message.chatId, message.tabId);
      }
    }
  }
  authenticated(request) {
    return !!this.session && request.profileId === this.profileId && request.sessionId === this.session.sessionId && request.capability === this.session.capability;
  }
  // The authority an operation started with: the global epoch and its chat's epoch.
  liveToken(request) {
    const chatId = request?.chatId;
    return {generation: this.generation, chatId, epoch: this.chatEpochs.get(chatId) || 0};
  }
  isLive(live) {
    return live.generation === this.generation && (this.chatEpochs.get(live.chatId) || 0) === live.epoch;
  }
  assertLive(live, lease) {
    if (!this.isLive(live) || !this.session || (lease && this.leases.get(lease.leaseId) !== lease)) throw fail('revoked');
  }
  async boundedDispatch(request, live = this.liveToken(request)) {
    if (this.quarantined) throw fail('previous_operation_still_pending');
    let timeout;
    const operation = this.dispatch(request, live);
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
  async releaseFromApp(message) {
    const lease = this.leases.get(message.leaseId);
    const reply = {type: 'response', id: message.id};
    if (!lease || lease.chatId !== message.chatId) {
      reply.error = {code: 'tab_lease_required'};
    } else {
      // Remove authority before any await, even when the ordinary request queue is busy.
      await this.dropLease(lease);
      reply.result = {released: true, closed: false};
    }
    if (this.authenticated(message)) {
      try { this.send(reply); } catch { /* The app will report an unknown outcome. */ }
    }
  }
  async releaseFromPopup(leaseId) {
    const lease = this.leases.get(leaseId);
    if (!lease) return this.status();
    const cleanup = this.dropLease(lease);
    this.announceDetached(lease);
    await cleanup;
    return this.status();
  }
  announceDetached({tabId, leaseId}) {
    try { this.send({type: 'event', event: 'detached', profileId: this.profileId, tabId, leaseId}); }
    catch { /* The coordinator discards disconnected leases. */ }
  }
  async dropLease(lease) {
    const {leaseId, tabId} = lease;
    this.leases.delete(leaseId);
    this.stopped.add(leaseId);
    this.documents.delete(tabId);
    this.dialogs.delete(tabId);
    this.shots.delete(tabId);
    this.dialogWaiters.get(tabId)?.();
    this.dialogWaiters.delete(tabId);
    const overlay = lease.overlay;
    clearInterval(overlay?.timer);
    const cleanup = this.attached.delete(tabId)
      ? this.removeOverlay(tabId, overlay).then(() => this.chrome.debugger.detach({tabId}))
      : this.attaching.get(tabId);
    if (cleanup) {
      this.detaching.set(tabId, cleanup);
      try { await cleanup; } catch { /* Already detached or attachment was cancelled. */ }
      this.detaching.delete(tabId);
    }
  }
  async revoke(chatId, tabId, invalidate = true) {
    if (invalidate && !tabId) {
      if (chatId) this.chatEpochs.set(chatId, (this.chatEpochs.get(chatId) || 0) + 1);
      else this.generation++;
    }
    const leases = [...this.leases.values()].filter(lease => (!chatId || lease.chatId === chatId) && (!tabId || lease.tabId === tabId));
    await Promise.all(leases.map(lease => this.dropLease(lease)));
    // Empty groups may remain in Chrome; unrelated and borrowed tabs stay open.
  }
  async stop(chatId, tabId) {
    const leaseIds = [...this.leases.values()].filter(x => (!chatId || x.chatId === chatId) && (!tabId || x.tabId === tabId)).map(x => x.leaseId);
    const cleanup = this.revoke(chatId, tabId);
    this.send({type: 'event', event: 'stop', version: VERSION, profileId: this.profileId, chatId, tabId, leaseIds});
    await cleanup;
    return this.status();
  }
  onDebuggerEvent(source, method, params = {}) {
    const tabId = source.tabId;
    if (!tabId) return;
    if (source.sessionId) return;
    if (method === 'Page.frameNavigated' && !params.frame?.parentId) {
      this.documents.delete(tabId); this.dialogs.delete(tabId); this.shots.delete(tabId);
      const lease = this.leaseForTab(tabId);
      if (lease?.overlay) {
        lease.overlay.contextId = undefined;
        lease.overlay.point = undefined;
        void this.refreshOverlay(lease);
      }
    }
    if (method === 'Page.navigatedWithinDocument') {
      const lease = this.leaseForTab(tabId);
      if (lease?.overlay && lease.overlay.frameId === params.frameId) {
        lease.overlay.point = undefined;
        void this.refreshOverlay(lease);
      }
    }
    if (method === 'Page.domContentEventFired') {
      const lease = this.leaseForTab(tabId);
      if (lease) void this.refreshOverlay(lease);
    }
    if (method === 'Page.javascriptDialogOpening') {
      this.dialogs.set(tabId, {url: params.url, documentToken: this.documents.get(tabId)});
      this.dialogWaiters.get(tabId)?.();
    }
    if (method === 'Page.javascriptDialogClosed') {
      this.dialogs.delete(tabId);
      const lease = this.leaseForTab(tabId);
      if (lease) void this.refreshOverlay(lease);
    }
  }
  async detach(tabId, debuggerDetached = false) {
    // Ignore our own debugger detach callback. onRemoved also covers tabs that never attached.
    if (debuggerDetached && !this.attached.has(tabId)) return;
    const lease = this.leaseForTab(tabId);
    if (!lease) return;
    if (debuggerDetached) this.attached.delete(tabId);
    const cleanup = this.dropLease(lease);
    this.announceDetached(lease);
    await cleanup;
  }
  leaseForTab(tabId) {
    return [...this.leases.values()].find(lease => lease.tabId === tabId);
  }
  titleChanged(tabId, title) {
    const lease = this.leaseForTab(tabId);
    if (!lease || typeof title !== 'string') return;
    lease.title = title.slice(0, 500);
    if ((this.session?.runtimeRevision || 0) < 5) return;
    try { this.send({type: 'event', event: 'tabTitle', tabId, leaseId: lease.leaseId, title: lease.title}); }
    catch { /* The coordinator clears lease metadata on disconnect. */ }
  }
  async remember(id, state, operation) {
    this.journal[id] = {state, operation, at: Date.now()};
    // Entries are bounded. Old actions cannot replay: coordinator retains its durable action journal.
    const entries = Object.entries(this.journal).sort((a, b) => b[1].at - a[1].at).slice(0, 1000);
    this.journal = Object.fromEntries(entries);
    await this.chrome.storage.local.set({journal: this.journal});
  }
  async dispatch(request, live = this.liveToken(request)) {
    if (!this.authenticated(request)) throw fail('unauthorized');
    if (JSON.stringify(request).length > MAX_FRAME || !identifier(request.id) || !identifier(request.chatId) || !OPERATIONS.has(request.operation)) throw fail('invalid_request');
    const mutation = MUTATIONS.has(request.operation);
    if (mutation && this.journal[request.id]) throw fail('outcome_unknown', this.chrome.i18n?.getMessage('outcomeUnknown') || 'outcome_unknown');
    const p = request.params || {};
    if (!p || typeof p !== 'object' || Array.isArray(p)) throw fail('invalid_params');
    if (mutation) await this.remember(request.id, 'dispatched', request.operation);
    this.assertLive(live);
    let result, held;
    if (request.operation === 'status') result = this.status();
    else if (request.operation === 'list') {
      const tabs = await this.chrome.tabs.query({});
      result = {tabs: tabs.filter(x => !x.incognito && websiteURL(x.url)).slice(0, 300).map(x => ({tabId: x.id, title: x.title?.slice(0, 500), url: x.url?.slice(0, 8192), leased: [...this.leases.values()].some(l => l.tabId === x.id)}))};
    } else if (['open', 'select'].includes(request.operation)) {
      result = await this.acquire(request, live);
      held = this.leases.get(result.leaseId);
      if (!held) throw fail('revoked');
    } else {
      const lease = this.leases.get(request.leaseId);
      if (!lease || lease.chatId !== request.chatId) throw fail('lease_required');
      this.assertLive(live, lease);
      if (request.operation === 'release') {
        if (p.close === true && !lease.created) throw fail('existing_tab_preserved');
        await this.revoke(lease.chatId, lease.tabId, false);
        this.assertLive(live);
        if (p.close === true) await this.chrome.tabs.remove(lease.tabId);
        result = {released: true, closed: p.close === true};
      } else {
        held = lease;
        const overlay = lease.overlay;
        if (overlay) {
          overlay.active = true;
          overlay.point = undefined;
          if (p.action !== 'dialog') void this.refreshOverlay(lease);
        }
        try { result = await this.operate(request, lease, live); }
        finally {
          if (overlay) {
            overlay.active = false;
            if (p.action !== 'dialog') void this.refreshOverlay(lease);
          }
        }
      }
    }
    // A tab revoked during the operation fails it, as its lease is gone; other tabs and chats continue.
    this.assertLive(live, held);
    if (mutation) await this.remember(request.id, 'completed', request.operation);
    this.assertLive(live, held);
    return result;
  }
  async acquire(request, live) {
    const p = request.params;
    if (!identifier(request.leaseId) || this.stopped.has(request.leaseId)) throw fail('invalid_lease');
    const created = request.operation === 'open';
    if (created ? !websiteURL(p.url) : !Number.isInteger(p.tabId)) throw fail('explicit_tab_selection_required');
    const requested = this.leases.get(request.leaseId);
    if (requested && (created || requested.tabId !== p.tabId || requested.chatId !== request.chatId)) throw fail('lease_exists');
    if (!created && !requested && p.userSelected !== true) throw fail('explicit_tab_selection_required');
    // Chrome removes a group when its last tab closes. Verify the cached group before
    // creating a tab; a failed lookup must not turn into a mutation or a blind retry.
    let groupId = created ? this.groups.get(request.chatId) : undefined;
    if (groupId !== undefined) {
      const groups = await this.chrome.tabGroups.query({});
      this.assertLive(live);
      if (!groups.some(group => group.id === groupId)) {
        this.groups.delete(request.chatId);
        groupId = undefined;
      }
    }
    let tab;
    if (created) tab = await this.chrome.tabs.create({url: p.url, active: false});
    else tab = await this.chrome.tabs.get(p.tabId);
    this.assertLive(live);
    if (tab.incognito || !websiteURL(tab.url || p.url)) throw fail('unsupported_page');
    if (this.detaching.has(tab.id)) throw fail('tab_release_pending');
    const existing = this.leaseForTab(tab.id);
    if (existing) {
      if (existing.chatId !== request.chatId) throw fail('tab_leased_by_another_chat:' + existing.chatId);
      this.assertLive(live, existing);
      return {tabId: tab.id, leaseId: existing.leaseId, url: tab.url, title: tab.title?.slice(0, 500),
        created: existing.created, resumed: true};
    }
    if (requested) throw fail('revoked');
    const lease = {leaseId: request.leaseId, chatId: request.chatId, tabId: tab.id, created, title: tab.title?.slice(0, 500)};
    this.leases.set(lease.leaseId, lease);
    // Existing user tabs are never moved into agent groups.
    if (created) {
      try {
        groupId = await this.chrome.tabs.group({tabIds: [tab.id], ...(groupId === undefined ? {} : {groupId})});
        this.assertLive(live, lease);
        this.groups.set(request.chatId, groupId);
        await this.chrome.tabGroups.update(groupId, {title: `Switchboard ${request.chatId.slice(0, 8)}`, color: 'blue'});
      } catch (error) {
        if (this.leases.get(lease.leaseId) === lease) await this.dropLease(lease);
        throw fail('tab_group_failed', error.message);
      }
    }
    this.assertLive(live, lease);
    lease.overlay = {active: false};
    lease.overlay.timer = setInterval(() => { void this.refreshOverlay(lease); }, 5000);
    lease.overlay.timer.unref?.();
    void this.refreshOverlay(lease, true);
    return {tabId: tab.id, leaseId: lease.leaseId, url: tab.url || p.url, title: lease.title, created};
  }
  async command(lease, live, method, params = {}) {
    this.assertLive(live, lease);
    return this.chrome.debugger.sendCommand({tabId: lease.tabId}, method, params);
  }
  // Chrome can leave an input command pending until its JavaScript dialog is handled.
  // Return the observed dialog to the caller so the next authorized request can handle it.
  // The original command is never replayed; its eventual rejection remains consumed.
  async inputCommand(lease, live, method, params) {
    let opened;
    const dialog = new Promise(resolve => { opened = () => resolve(true); });
    this.dialogWaiters.set(lease.tabId, opened);
    try {
      const pending = await Promise.race([
        this.command(lease, live, method, params).then(() => false), dialog
      ]);
      this.assertLive(live, lease);
      return pending;
    } finally {
      if (this.dialogWaiters.get(lease.tabId) === opened) this.dialogWaiters.delete(lease.tabId);
    }
  }
  async attach(lease, live) {
    const {tabId} = lease;
    this.assertLive(live, lease);
    if (this.attaching.has(tabId)) return this.attaching.get(tabId);
    if (this.attached.has(tabId)) return;
    const attachment = (async () => {
      await this.attachDebugger(lease, live);
      await this.command(lease, live, 'Page.enable');
    })();
    this.attaching.set(tabId, attachment);
    try { await attachment; } finally { this.attaching.delete(tabId); }
  }
  async attachDebugger(lease, live) {
    const {tabId} = lease;
    try { await this.chrome.debugger.attach({tabId}, '1.3'); }
    catch (error) { throw fail('debugger_conflict', error.message); }
    try { this.assertLive(live, lease); }
    catch (error) {
      try { await this.chrome.debugger.detach({tabId}); } catch {}
      throw error;
    }
    this.attached.add(tabId);
  }
  async world(lease, live, frameId) {
    const tree = await this.command(lease, live, 'Page.getFrameTree');
    const frames = [];
    const visit = (node, depth) => {
      if (depth > 3 || frames.length >= 50) return;
      frames.push({frameId: node.frame.id, url: node.frame.url, name: node.frame.name || '', main: depth === 0});
      for (const child of node.childFrames || []) visit(child, depth + 1);
    };
    visit(tree.frameTree, 0);
    const frame = frameId ? frames.find(x => x.frameId === frameId) : frames[0];
    if (!frame || !websiteURL(frame.url)) throw fail('unsupported_frame');
    const world = await this.command(lease, live, 'Page.createIsolatedWorld', {frameId: frame.frameId, worldName: 'Switchboard bounded tools v1'});
    return {contextId: world.executionContextId, frame, frames};
  }
  async evaluate(lease, live, contextId, fn, args) {
    const result = await this.command(lease, live, 'Runtime.evaluate', {
      contextId, expression: `(${fn.toString()})(${JSON.stringify(args)})`, returnByValue: true, awaitPromise: false, timeout: 3000});
    if (result.exceptionDetails) throw fail('page_operation_failed', result.exceptionDetails.exception?.description?.slice(0, 500) || result.exceptionDetails.text);
    return result.result?.value;
  }
  async refreshOverlay(lease, attachForNewLease = false) {
    const overlay = lease.overlay;
    if (!overlay || !this.session || this.leases.get(lease.leaseId) !== lease || this.dialogs.has(lease.tabId)) return;
    if (overlay.pending) {
      overlay.dirty = true;
      return;
    }
    overlay.pending = true;
    const live = this.liveToken(lease);
    try {
      if (!this.attached.has(lease.tabId)) {
        if (!attachForNewLease) return;
        const tab = await this.chrome.tabs.get(lease.tabId);
        this.assertLive(live, lease);
        if (!websiteURL(tab.url) || tab.incognito) return;
        await this.attach(lease, live);
      }
      if (overlay.contextId === undefined) {
        const world = await this.world(lease, live);
        overlay.contextId = world.contextId;
        overlay.frameId = world.frame.frameId;
      }
      const label = this.chrome.i18n?.getMessage(overlay.active ? 'tabOverlayActive' : 'tabOverlayIdle') || 'Switchboard';
      await this.evaluate(lease, live, overlay.contextId, renderTabOverlay, {active: overlay.active, point: overlay.point, label});
    } catch {
      // Transient navigation, debugger conflicts and unsupported pages do not change tool outcomes.
      overlay.contextId = undefined;
    } finally {
      overlay.pending = false;
      if (overlay.dirty) {
        overlay.dirty = false;
        void this.refreshOverlay(lease);
      }
    }
  }
  async removeOverlay(tabId, overlay) {
    if (overlay?.contextId === undefined) return;
    // The lease is already revoked. Remove only the fixed indicator in its last isolated world.
    let timeout;
    try {
      await Promise.race([
        this.chrome.debugger.sendCommand({tabId}, 'Runtime.evaluate', {
          contextId: overlay.contextId, expression: `(${renderTabOverlay.toString()})({"remove":true})`, timeout: 300
        }),
        new Promise(resolve => { timeout = setTimeout(resolve, 300); })
      ]);
    } catch { /* Closed or replaced documents discard the indicator. Other failures expire locally. */ }
    finally { clearTimeout(timeout); }
  }
  markPointer(lease, frame, point, documentToken) {
    // Element coordinates from a subframe can be approximate (e.g. CSS transforms).
    if (!frame.main || !lease.overlay) return;
    lease.overlay.point = {x: point.x, y: point.y, documentToken, expires: Date.now() + 900};
    void this.refreshOverlay(lease);
  }
  async operate(request, lease, live) {
    const p = request.params;
    if (request.operation === 'input') validateInput(p);
    if (['read', 'screenshot'].includes(request.operation) && p.waitSeconds !== undefined &&
        !(Number.isFinite(p.waitSeconds) && p.waitSeconds >= 0.1 && p.waitSeconds <= 10)) throw fail('invalid_wait_seconds');
    const tab = await this.chrome.tabs.get(lease.tabId);
    if (!websiteURL(tab.url)) throw fail('unsupported_page');
    if (p.expectedURL && p.expectedURL !== tab.url) throw fail('stale_navigation');
    const isMutation = ['input', 'upload'].includes(request.operation);
    if (isMutation && (!p.expectedURL || !identifier(p.documentToken))) throw fail('observation_required');
    await this.attach(lease, live);
    if (p.action !== 'dialog') void this.refreshOverlay(lease);
    if (request.operation === 'input' && p.action === 'dialog') {
      const dialog = this.dialogs.get(lease.tabId);
      if (!dialog || dialog.documentToken !== p.documentToken || dialog.url !== p.expectedURL) throw fail('dialog_observation_required');
      if (typeof p.accept !== 'boolean' || (p.promptText && (typeof p.promptText !== 'string' || p.promptText.length > 5000))) throw fail('invalid_dialog');
      await this.command(lease, live, 'Page.handleJavaScriptDialog', {accept: p.accept, promptText: p.promptText || ''});
      return {handled: true};
    }
    if (p.waitSeconds !== undefined) {
      // A bounded pause before observing, for pages that are still loading or animating.
      await new Promise(resolve => setTimeout(resolve, p.waitSeconds * 1000));
      this.assertLive(live, lease);
    }
    if (request.operation === 'screenshot') return this.screenshot(lease, live, p);
    const world = await this.world(lease, live, p.frameId);
    if (['read', 'find', 'verify'].includes(request.operation)) {
      if (request.operation === 'find' && (typeof p.query !== 'string' || !p.query.trim() || p.query.length > 500)) throw fail('query_required');
      const result = await this.evaluate(lease, live, world.contextId, observePage, {query: p.query});
      if (world.frame.main) this.documents.set(lease.tabId, result.documentToken);
      return {...result, tabId: lease.tabId, frameId: world.frame.frameId, frames: world.frames};
    }
    // Check the actual observed document in the isolated world immediately before every input.
    const current = await this.evaluate(lease, live, world.contextId, pageInfo, {});
    if (current.documentToken !== p.documentToken) throw fail('stale_document');
    if (p.expectedURL !== tab.url) throw fail('stale_navigation');
    if (request.operation === 'upload') {
      validateFiles(p.files);
      return this.evaluate(lease, live, world.contextId, installUpload, {ref: p.ref, documentToken: p.documentToken, files: p.files});
    }
    if (request.operation !== 'input') throw fail('unsupported_operation');
    const byPoint = p.x !== undefined;
    // Coordinates are pixels of the latest screenshot of the whole tab: map them before anything can scroll.
    const shotPoint = byPoint || (p.action === 'scroll' && !p.ref) ? await this.mapPoint(lease, live, world, p) : null;
    // Element positions inside a frame are local to it; Chrome dispatches input in main-viewport CSS pixels.
    const offset = world.frame.main ? {x: 0, y: 0} : await this.frameOffset(lease, live, world.frame);
    const resolve = async (args) => {
      const found = await this.evaluate(lease, live, world.contextId, resolveElement, {ref: p.ref, documentToken: p.documentToken, ...args});
      return {...found, x: found.x + offset.x, y: found.y + offset.y};
    };
    if (p.action === 'scroll_to') {
      const found = await resolve({allowObscured: true, allowDisabled: true});
      return {performed: p.action, x: found.x, y: found.y, observationRequired: true, screenshotStale: true};
    }
    // Chrome acknowledges pointer/key dispatch to inactive tabs without delivering DOM events.
    // Select only this authorized lease; never foreground the browser window or switch back later.
    if (!tab.active) {
      await this.chrome.tabs.update(lease.tabId, {active: true});
      this.assertLive(live, lease);
    }
    const pending = {dialogPending: true, observationRequired: true};
    const extra = {};
    if (POINTER[p.action] || (p.action === 'type' && p.ref) || p.action === 'set_value') {
      let point;
      if (p.action === 'set_value' && typeof p.value === 'string') {
        const chosen = await this.evaluate(lease, live, world.contextId, selectOption, {ref: p.ref, documentToken: p.documentToken, value: p.value});
        return {performed: p.action, ...chosen, observationRequired: true};
      }
      if (p.action === 'set_value') {
        const found = await resolve({click: true});
        if (found.checked === undefined) throw fail('ref_is_not_checkable');
        if (found.checked === p.checked) return {performed: p.action, unchanged: true, checked: found.checked, observationRequired: true};
        if (found.type === 'radio' && p.checked === false) throw fail('radio_cannot_be_unchecked');
        point = found;
      } else if (byPoint) {
        point = shotPoint;
        Object.assign(extra, await this.classifyPoint(lease, live, world, point));
      } else {
        point = await resolve({click: true});
      }
      await this.assertInViewport(lease, live, point);
      const [button, count] = POINTER[p.action] || POINTER.click;
      for (const event of mouseEvents(point, button, count)) {
        if (await this.inputCommand(lease, live, 'Input.dispatchMouseEvent', event)) return pending;
        if (event.type === 'mouseMoved') this.markPointer(lease, world.frame, event, p.documentToken);
      }
      if (p.action === 'type') {
        const afterClick = await this.evaluate(lease, live, world.contextId, pageInfo, {});
        if (afterClick.documentToken !== p.documentToken) throw fail('stale_document');
        await resolve({focus: true});
        if (await this.inputCommand(lease, live, 'Input.insertText', {text: p.text})) return pending;
      }
    } else if (p.action === 'type') {
      await this.assertFocus(lease, live, world, {editable: true});
      if (await this.inputCommand(lease, live, 'Input.insertText', {text: p.text})) return pending;
    } else if (p.action === 'key') {
      const events = keyEvents(p.key);
      if (p.ref) await resolve({focus: true, allowObscured: true});
      // A printable key would type into the focused element: the same sensitive-field rule as type.
      else if (events[0].text) await this.assertFocus(lease, live, world, {});
      for (const event of events) {
        if (await this.inputCommand(lease, live, 'Input.dispatchKeyEvent', event)) return pending;
      }
    } else if (p.action === 'scroll') {
      const point = p.ref ? await resolve({allowObscured: true, allowDisabled: true}) : shotPoint;
      for (const event of [{type: 'mouseMoved', x: point.x, y: point.y, button: 'none', buttons: 0},
        {type: 'mouseWheel', x: point.x, y: point.y, deltaX: p.deltaX || 0, deltaY: p.deltaY || 0}]) {
        if (await this.inputCommand(lease, live, 'Input.dispatchMouseEvent', event)) return pending;
        if (event.type === 'mouseMoved') this.markPointer(lease, world.frame, event, p.documentToken);
      }
      return {performed: p.action, observationRequired: true, screenshotStale: true};
    } else throw fail('unsupported_input');
    return {performed: p.action, ...extra, observationRequired: true};
  }
  async viewport(lease, live) {
    const metrics = await this.command(lease, live, 'Page.getLayoutMetrics');
    const viewport = metrics.cssVisualViewport || metrics.visualViewport;
    if (!viewport || !(viewport.clientWidth > 0) || !(viewport.clientHeight > 0)) throw fail('empty_viewport');
    return viewport;
  }
  async screenshot(lease, live, p) {
    const world = await this.world(lease, live);
    const info = await this.evaluate(lease, live, world.contextId, pageInfo, {});
    const viewport = await this.viewport(lease, live);
    const ratio = Number.isFinite(info.devicePixelRatio) && info.devicePixelRatio > 0 ? info.devicePixelRatio : 1;
    let region = {x: viewport.pageX, y: viewport.pageY, width: viewport.clientWidth, height: viewport.clientHeight};
    let zoom = null;
    if (p.clip !== undefined) {
      // Zoom: a region of the latest full screenshot, in its pixels, at up to native resolution.
      const c = p.clip;
      if (!c || typeof c !== 'object' || !['x', 'y', 'width', 'height'].every(k => Number.isFinite(c[k])) || c.width < 1 || c.height < 1) throw fail('invalid_clip');
      const shot = this.currentShot(lease, info, viewport);
      if (c.x < 0 || c.y < 0 || c.x + c.width > shot.imageWidth || c.y + c.height > shot.imageHeight) throw fail('clip_outside_screenshot');
      const sx = shot.cssWidth / shot.imageWidth, sy = shot.cssHeight / shot.imageHeight;
      region = {x: viewport.pageX + c.x * sx, y: viewport.pageY + c.y * sy, width: c.width * sx, height: c.height * sy};
      zoom = {x: c.x, y: c.y, width: c.width, height: c.height};
    }
    const scale = Math.min(1, MAX_IMAGE_SIDE / (Math.max(region.width, region.height) * ratio));
    const result = await this.command(lease, live, 'Page.captureScreenshot', {format: 'jpeg', quality: 60,
      captureBeyondViewport: false, clip: {...region, scale}});
    if (typeof result.data !== 'string' || result.data.length > 700000) throw fail('screenshot_too_large');
    const size = jpegSize(result.data);
    if (!size) throw fail('screenshot_format_unknown');
    const metadata = {width: size.width, height: size.height, url: info.url, documentToken: info.documentToken,
      viewport: {width: viewport.clientWidth, height: viewport.clientHeight}};
    if (zoom) return {mimeType: 'image/jpeg', base64: result.data, ...metadata, zoom,
      note: 'Zoomed region. Coordinates for input stay pixels of the latest full screenshot.'};
    this.shots.set(lease.tabId, {imageWidth: size.width, imageHeight: size.height, cssWidth: viewport.clientWidth,
      cssHeight: viewport.clientHeight, pageX: viewport.pageX, pageY: viewport.pageY, documentToken: info.documentToken, url: info.url});
    return {mimeType: 'image/jpeg', base64: result.data, ...metadata};
  }
  // The stored mapping, only while the same document shows the same viewport (size and scroll position).
  currentShot(lease, info, viewport) {
    const shot = this.shots.get(lease.tabId);
    if (!shot) throw fail('screenshot_required', 'screenshot_required: take a screenshot first; x,y are pixels of the latest screenshot');
    const same = (a, b, tolerance) => Math.abs(a - b) <= tolerance;
    if (shot.documentToken !== info.documentToken || shot.url !== info.url || !same(shot.cssWidth, viewport.clientWidth, 0.5) ||
        !same(shot.cssHeight, viewport.clientHeight, 0.5) || !same(shot.pageX, viewport.pageX, 1) || !same(shot.pageY, viewport.pageY, 1)) {
      throw fail('screenshot_stale', 'screenshot_stale: the page scrolled, resized or changed since the latest screenshot; take a new one');
    }
    return shot;
  }
  async mapPoint(lease, live, world, p) {
    if (!world.frame.main) throw fail('coordinates_are_tab_pixels', 'coordinates_are_tab_pixels: omit frameId with x,y');
    const viewport = await this.viewport(lease, live);
    if (p.x === undefined) return {x: viewport.clientWidth / 2, y: viewport.clientHeight / 2};
    const info = await this.evaluate(lease, live, world.contextId, pageInfo, {});
    const shot = this.currentShot(lease, info, viewport);
    if (p.x < 0 || p.y < 0 || p.x > shot.imageWidth || p.y > shot.imageHeight) throw fail('coordinates_outside_screenshot');
    return {x: p.x * shot.cssWidth / shot.imageWidth, y: p.y * shot.cssHeight / shot.imageHeight};
  }
  async assertInViewport(lease, live, point) {
    const viewport = await this.viewport(lease, live);
    if (!(point.x >= 0 && point.y >= 0 && point.x <= viewport.clientWidth && point.y <= viewport.clientHeight)) throw fail('element_outside_viewport');
  }
  // Top-viewport CSS content box {x, y, width, height} of a frame's owner element.
  async frameOffset(lease, live, frame) {
    let owner;
    try { owner = await this.command(lease, live, 'DOM.getFrameOwner', {frameId: frame.frameId}); }
    catch (error) {
      if (error.code === 'revoked') throw error;
      throw fail('frame_input_unsupported', this.chrome.i18n?.getMessage('frameInputUnsupported') || error.message);
    }
    const box = await this.command(lease, live, 'DOM.getBoxModel', {backendNodeId: owner.backendNodeId});
    const quad = box?.model?.content;
    if (!Array.isArray(quad) || quad.length < 8 || !quad.every(Number.isFinite)) throw fail('frame_position_unknown');
    return {x: quad[0], y: quad[1], width: quad[2] - quad[0], height: quad[5] - quad[1]};
  }
  // Risk of the element under a top-viewport point: sensitive fields and file inputs are refused.
  async classifyPoint(lease, live, world, point) {
    let found = await this.evaluate(lease, live, world.contextId, inspectPoint, point);
    if (found.crossFrame) {
      found = null;
      // The innermost frame whose box contains the point, when this tab's debugger can enter it.
      let best = null;
      for (const frame of world.frames.filter(x => !x.main)) {
        try {
          const offset = await this.frameOffset(lease, live, frame);
          const area = offset.width * offset.height;
          if (point.x >= offset.x && point.y >= offset.y && point.x <= offset.x + offset.width && point.y <= offset.y + offset.height &&
              (!best || area < best.area)) best = {frame, offset, area};
        } catch (error) { if (error.code === 'revoked') throw error; }
      }
      if (best) {
        try {
          const inner = await this.world(lease, live, best.frame.frameId);
          found = await this.evaluate(lease, live, inner.contextId, inspectPoint, {x: point.x - best.offset.x, y: point.y - best.offset.y});
          if (found.crossFrame) found = null;
        } catch (error) { if (error.code === 'revoked') throw error; found = null; }
      }
      // A frame in another process cannot be inspected: click it, but say so.
      if (!found) return {classified: false};
    }
    if (found.sensitive) throw fail('sensitive_input');
    if (found.file) throw fail('file_input_use_upload', 'file_input_use_upload: a click would open the native file picker; use upload with the field ref');
    return {};
  }
  // The focused element must be a verifiable, non-sensitive target before text or printable keys go to it.
  async assertFocus(lease, live, world, {editable}) {
    let focus = await this.evaluate(lease, live, world.contextId, inspectFocus, {});
    if (focus.crossFrame) {
      focus = null;
      for (const frame of world.frames.filter(x => !x.main)) {
        try {
          const inner = await this.world(lease, live, frame.frameId);
          const found = await this.evaluate(lease, live, inner.contextId, inspectFocus, {});
          if (found.focused && !found.crossFrame) { focus = found; break; }
        } catch (error) { if (error.code === 'revoked') throw error; }
      }
      if (!focus) throw fail('focused_element_unverified', 'focused_element_unverified: focus is in a frame this tab cannot inspect; use a ref');
    }
    if (!focus.focused) throw fail('no_focused_element', 'no_focused_element: click the field first or pass its ref');
    if (focus.sensitive) throw fail('sensitive_input');
    if (editable && !focus.editable) throw fail('focused_element_not_editable');
  }
}

// Validate every input argument before Chrome is touched.
export function validateInput(p) {
  if (!INPUT_ACTIONS.has(p.action)) throw fail('unsupported_input');
  const ref = p.ref !== undefined;
  const point = p.x !== undefined || p.y !== undefined;
  if (ref && !/^ref_\d{1,9}$/.test(p.ref)) throw fail('invalid_ref');
  if (point && !(Number.isFinite(p.x) && Number.isFinite(p.y))) throw fail('invalid_coordinates');
  if (ref && point) throw fail('use_either_ref_or_coordinates');
  if (POINTER[p.action] && !ref && !point) throw fail('ref_or_coordinates_required');
  if (['type', 'key', 'scroll_to', 'set_value'].includes(p.action) && point) throw fail('coordinates_not_supported');
  if (['scroll_to', 'set_value'].includes(p.action) && !ref) throw fail('ref_required');
  if (p.action === 'type' && (typeof p.text !== 'string' || !p.text.length || p.text.length > 5000)) throw fail('text_too_large');
  if (p.action === 'key' && !keyEvents(p.key)) throw fail('unsupported_key');
  if (p.action === 'scroll' && !([p.deltaX || 0, p.deltaY || 0].every(v => Number.isFinite(v) && Math.abs(v) <= 5000) && (p.deltaX || p.deltaY))) throw fail('invalid_scroll');
  if (p.action === 'set_value' && !((typeof p.value === 'string' && p.value.length > 0 && p.value.length <= 500 && p.checked === undefined) ||
      (typeof p.checked === 'boolean' && p.value === undefined))) throw fail('value_or_checked_required');
}

// Ordered Input.dispatchMouseEvent parameters in CSS pixels; count 2 and 3 are double and triple clicks.
export function mouseEvents(point, button, count) {
  const held = button === 'right' ? 2 : 1;
  const events = [{type: 'mouseMoved', x: point.x, y: point.y, button: 'none', buttons: 0}];
  for (let n = 1; n <= count; n++) {
    events.push({type: 'mousePressed', x: point.x, y: point.y, button, buttons: held, clickCount: n},
      {type: 'mouseReleased', x: point.x, y: point.y, button, buttons: 0, clickCount: n});
  }
  return events;
}

// Closed key list with modifier chords, as in the isolated browser (BrowserRuntime/page_input.py key_events).
const MODIFIERS = {alt: 1, option: 1, ctrl: 2, control: 2, cmd: 4, command: 4, meta: 4, shift: 8};
const NAMED = {
  enter: ['Enter', 'Enter', 13, '\r'], return: ['Enter', 'Enter', 13, '\r'], tab: ['Tab', 'Tab', 9, null],
  escape: ['Escape', 'Escape', 27, null], esc: ['Escape', 'Escape', 27, null], backspace: ['Backspace', 'Backspace', 8, null],
  delete: ['Delete', 'Delete', 46, null], space: [' ', 'Space', 32, ' '],
  arrowup: ['ArrowUp', 'ArrowUp', 38, null], up: ['ArrowUp', 'ArrowUp', 38, null],
  arrowdown: ['ArrowDown', 'ArrowDown', 40, null], down: ['ArrowDown', 'ArrowDown', 40, null],
  arrowleft: ['ArrowLeft', 'ArrowLeft', 37, null], left: ['ArrowLeft', 'ArrowLeft', 37, null],
  arrowright: ['ArrowRight', 'ArrowRight', 39, null], right: ['ArrowRight', 'ArrowRight', 39, null],
  home: ['Home', 'Home', 36, null], end: ['End', 'End', 35, null], pageup: ['PageUp', 'PageUp', 33, null], pagedown: ['PageDown', 'PageDown', 34, null]
};
// macOS editing shortcuts are browser commands, not text; CDP needs them named.
const COMMANDS = {'a:4': 'selectAll', 'c:4': 'copy', 'x:4': 'cut', 'v:4': 'paste', 'z:4': 'undo', 'z:12': 'redo'};
export function keyEvents(combo) {
  if (typeof combo !== 'string' || !combo.length || combo.length > 40) return null;
  const parts = combo.trim().split(/\+(?!$)/).filter(Boolean);
  if (!parts.length) return null;
  const main = parts.pop();
  let modifiers = 0;
  for (const name of parts) {
    const bit = MODIFIERS[name.toLowerCase()];
    if (!bit || modifiers & bit) return null;
    modifiers |= bit;
  }
  let key, code, virtual, text;
  const named = NAMED[main.toLowerCase()];
  if (named) [key, code, virtual, text] = named;
  else if (main.length === 1 && /^[\x21-\x7e]$/.test(main)) {
    key = main; text = main;
    if (/[a-z]/i.test(main)) { code = 'Key' + main.toUpperCase(); virtual = main.toUpperCase().charCodeAt(0); if (modifiers & 8) key = text = main.toUpperCase(); }
    else if (/\d/.test(main)) { code = 'Digit' + main; virtual = main.charCodeAt(0); }
    else { code = ''; virtual = 0; }
  } else return null;
  if (modifiers & 6) text = null; // Ctrl/Cmd combos are shortcuts, never typed characters.
  const down = {type: text ? 'keyDown' : 'rawKeyDown', key, code, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual, modifiers};
  if (text) Object.assign(down, {text, unmodifiedText: text});
  const command = COMMANDS[`${main.toLowerCase()}:${modifiers}`];
  if (command) down.commands = [command];
  return [down, {type: 'keyUp', key, code, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual, modifiers}];
}

// Width and height from a base64 JPEG's start-of-frame marker.
export function jpegSize(base64) {
  let bytes;
  try {
    const head = base64.slice(0, 87384);
    bytes = Uint8Array.from(atob(head.slice(0, head.length - head.length % 4)), c => c.charCodeAt(0));
  } catch { return null; }
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  for (let i = 2; i + 9 < bytes.length;) {
    if (bytes[i] !== 0xff) return null;
    const marker = bytes[i + 1];
    const length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return {height: (bytes[i + 5] << 8) | bytes[i + 6], width: (bytes[i + 7] << 8) | bytes[i + 8]};
    }
    i += 2 + length;
  }
  return null;
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
