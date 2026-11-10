import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {Controller, validateFiles, websiteURL} from './controller.js';
globalThis.crypto ||= webcrypto;
const event = () => ({addListener() {}});
function mockChrome(stored = {}) {
  const calls = [], tabs = new Map([[10, {id: 10, url: 'https://example.org/', title: 'Existing'}]]);
  const chrome = {
    calls, tabsById: tabs,
    storage: {local: {async get() {return structuredClone(stored);}, async set(value) {Object.assign(stored, structuredClone(value));}}},
    runtime: {id: 'testextension', connectNative() {return {onMessage: event(), onDisconnect: event(), postMessage(value) {calls.push(['post', value]);}};}},
    alarms: {async create() {}},
    tabs: {
      async update(id, value) {calls.push(['update', id, value]); Object.assign(tabs.get(id), value); return tabs.get(id);},
      async query() {return [...tabs.values()];}, async get(id) {assert.ok(tabs.has(id)); return {...tabs.get(id)};},
      async create(value) {calls.push(['create', value]); const tab = {id: 20, ...value}; tabs.set(20, tab); return tab;},
      async remove(id) {calls.push(['remove', id]); tabs.delete(id);},
      async group(value) {calls.push(['group', value]); return 42;}
    },
    tabGroups: {async query() {return [{id: 42}];}, async update(id, value) {calls.push(['groupUpdate', id, value]);}},
    debugger: {
      async attach(target) {calls.push(['attach', target]);}, async detach(target) {calls.push(['detach', target]);},
      async sendCommand(target, method, params) {
        calls.push(['cdp', method, params]);
        if (method === 'Page.getFrameTree') return {frameTree: {frame: {id: 'frame1', url: tabs.get(target.tabId).url}}};
        if (method === 'Page.createIsolatedWorld') return {executionContextId: 1};
        if (method === 'Runtime.evaluate') return {result: {value: {url: tabs.get(target.tabId).url, documentToken: 'doc1', x: 30, y: 40}}};
        if (method === 'Page.getLayoutMetrics') return {cssVisualViewport: {pageX: 0, pageY: 0, clientWidth: 800, clientHeight: 600}};
        if (method === 'Page.captureScreenshot') return {data: 'AA=='};
        return {};
      }
    }
  };
  return chrome;
}
async function paired(chrome = mockChrome(), options) {
  const controller = new Controller(chrome, options); await controller.initialize();
  await controller.welcome({version: 1, profileId: controller.profileId, paired: true, sessionId: 'session1', capability: 'cap1'});
  return controller;
}
function request(controller, operation, params = {}, more = {}) {
  return {type: 'request', id: crypto.randomUUID(), profileId: controller.profileId, chatId: 'chat1',
    sessionId: 'session1', capability: 'cap1', operation, params, ...more};
}
async function select(controller, more = {}) {
  return controller.dispatch(request(controller, 'select', {tabId: 10, userSelected: true}, {leaseId: 'lease1', ...more}));
}
test('authority fails closed before touching Chrome', async () => {
  const controller = await paired();
  for (const bad of [{capability: 'wrong'}, {sessionId: 'old'}, {profileId: 'other'}, {operation: 'Runtime.evaluate'}]) {
    await assert.rejects(controller.dispatch(request(controller, 'list', {}, bad)));
  }
  assert.equal(controller.chrome.calls.length, 0);
});
test('explicit handoff and one chat lease protect existing tabs', async () => {
  const controller = await paired();
  await assert.rejects(controller.dispatch(request(controller, 'select', {tabId: 10}, {leaseId: 'lease1'})), /explicit_tab_selection_required/);
  await select(controller);
  await assert.rejects(select(controller, {leaseId: 'lease2', chatId: 'chat2'}), /tab_busy/);
  await assert.rejects(controller.dispatch(request(controller, 'read', {}, {leaseId: 'lease1', chatId: 'chat2'})), /lease_required/);
  await assert.rejects(controller.dispatch(request(controller, 'release', {close: true}, {leaseId: 'lease1'})), /existing_tab_preserved/);
  await controller.stop();
  assert.equal(controller.leases.size, 0);
  assert.ok(controller.chrome.tabsById.has(10));
  assert.ok(!controller.chrome.calls.some(x => ['remove', 'group'].includes(x[0])));
});
test('agent tabs receive groups and only created tabs can close', async () => {
  const controller = await paired();
  const result = await controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'lease2'}));
  assert.equal(result.tabId, 20);
  assert.ok(controller.chrome.calls.some(x => x[0] === 'group'));
  await controller.dispatch(request(controller, 'release', {close: true}, {leaseId: 'lease2'}));
  assert.ok(!controller.chrome.tabsById.has(20));
  assert.ok(controller.chrome.tabsById.has(10));
});
test('privileged URLs and arbitrary native paths never cross browser boundary', async () => {
  for (const value of ['chrome://settings', 'file:///etc/passwd', 'javascript:alert(1)', 'data:text/html,test', 'chrome-extension://id/x']) assert.equal(websiteURL(value), false);
  const controller = await paired();
  await assert.rejects(controller.dispatch(request(controller, 'open', {url: 'file:///tmp/a'}, {leaseId: 'lease2'})));
  assert.equal(controller.chrome.calls.length, 0);
  assert.throws(() => validateFiles([{name: '../secret', mimeType: 'text/plain', base64: 'AA=='}]));
  assert.throws(() => validateFiles([{name: 'a', mimeType: 'text/plain', base64: 'x'.repeat(700004)}]));
  assert.doesNotThrow(() => validateFiles([{name: 'a.txt', mimeType: 'text/plain', base64: 'aGk='}]));
});
test('stale navigation and document references reject before input', async () => {
  const controller = await paired(); await select(controller);
  for (const params of [
    {action: 'click', ref: 'ref_1'},
    {action: 'click', ref: 'ref_1', expectedURL: 'https://wrong.org/', documentToken: 'doc1'},
    {action: 'click', ref: 'ref_1', expectedURL: 'https://example.org/', documentToken: 'oldDoc'}
  ]) await assert.rejects(controller.dispatch(request(controller, 'input', params, {leaseId: 'lease1'})));
  assert.ok(!controller.chrome.calls.some(x => x[0] === 'cdp' && x[1].startsWith('Input.')));
});
test('ambiguous mutation IDs survive worker restart and never replay', async () => {
  const stored = {}; const chrome = mockChrome(stored); const controller = await paired(chrome);
  const action = request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'lease2'});
  chrome.tabs.create = async () => {throw new Error('transport lost after submission');};
  await assert.rejects(controller.dispatch(action));
  assert.equal(stored.journal[action.id].state, 'dispatched');
  const restarted = await paired(mockChrome(stored));
  await assert.rejects(restarted.dispatch({...action, profileId: restarted.profileId}), /outcome_unknown/);
  assert.ok(!restarted.chrome.calls.some(x => x[0] === 'create'));
});
test('stop cancels an in-flight command before further commands', async () => {
  const controller = await paired(); await select(controller);
  let resume;
  controller.chrome.debugger.attach = () => new Promise(resolve => {resume = resolve;});
  const pending = controller.dispatch(request(controller, 'read', {}, {leaseId: 'lease1'}));
  await new Promise(resolve => setImmediate(resolve));
  await controller.stop(); resume();
  await assert.rejects(pending, /revoked/);
  assert.ok(!controller.chrome.calls.some(x => x[0] === 'cdp'));
  assert.ok(controller.chrome.calls.some(x => x[0] === 'detach'));
});
test('reconnection grants fresh authority and drops old leases', async () => {
  const controller = await paired(); await select(controller);
  await controller.welcome({version: 1, profileId: controller.profileId, paired: true, sessionId: 'session2', capability: 'cap2'});
  assert.equal(controller.leases.size, 0);
  await assert.rejects(controller.dispatch(request(controller, 'list')), /unauthorized/);
  assert.ok(controller.chrome.tabsById.has(10));
});

test('JavaScript dialog handling uses observed document and never evaluates a blocked page', async () => {
  const controller = await paired(); await select(controller);
  await controller.dispatch(request(controller, 'read', {}, {leaseId: 'lease1'}));
  controller.onDebuggerEvent({tabId: 10}, 'Page.javascriptDialogOpening', {url: 'https://example.org/'});
  controller.chrome.calls.length = 0;
  await controller.dispatch(request(controller, 'input', {action: 'dialog', accept: false, expectedURL: 'https://example.org/', documentToken: 'doc1'}, {leaseId: 'lease1'}));
  assert.ok(controller.chrome.calls.some(x => x[0] === 'cdp' && x[1] === 'Page.handleJavaScriptDialog'));
  assert.ok(!controller.chrome.calls.some(x => x[0] === 'cdp' && x[1] === 'Runtime.evaluate'));
  controller.onDebuggerEvent({tabId: 10}, 'Page.frameNavigated', {frame: {id: 'frame1'}});
  await assert.rejects(controller.dispatch(request(controller, 'input', {action: 'dialog', accept: true, expectedURL: 'https://example.org/', documentToken: 'doc1'}, {leaseId: 'lease1'})), /dialog_observation_required/);
});

test('pairing proof persists across worker restarts but never enters status', async () => {
  const stored = {}; const controller = await paired(mockChrome(stored));
  assert.equal(controller.hello().pairingSecret, undefined);
  await controller.welcome({version: 1, profileId: controller.profileId, paired: true, sessionId: 'session2', capability: 'cap2', pairingSecret: 'privateReconnectProof'});
  const restarted = new Controller(mockChrome(stored)); await restarted.initialize();
  assert.equal(restarted.hello().pairingSecret, 'privateReconnectProof');
  assert.equal(restarted.status().pairingSecret, undefined);
});

test('a hung tab close expires, invalidates authority, and never starts queued Chrome work', async () => {
  const stored = {}, chrome = mockChrome(stored);
  const controller = await paired(chrome, {operationTimeoutMs: 30});
  await controller.connect();
  await controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'createdLease'}));
  let finishClose, queries = 0;
  chrome.tabs.remove = () => new Promise(resolve => { finishClose = resolve; });
  chrome.tabs.query = async () => { queries++; return []; };
  const release = request(controller, 'release', {close: true}, {leaseId: 'createdLease'});
  controller.receive(release);
  controller.receive(request(controller, 'list'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(typeof finishClose, 'function');
  assert.equal(controller.pending, 2);
  assert.equal(controller.status().connected, true);
  assert.equal(queries, 0);
  await controller.queue;
  assert.equal(controller.pending, 0);
  assert.equal(queries, 0);
  assert.equal(controller.session, null);
  assert.equal(controller.leases.size, 0);
  assert.equal(controller.status().connected, false);
  assert.equal(controller.quarantined, true);
  assert.equal(stored.journal[release.id].state, 'dispatched');
  const reply = chrome.calls.find(x => x[0] === 'post' && x[1].id === release.id)?.[1];
  assert.equal(reply.error.code, 'operation_timeout_unknown_outcome');
  await controller.connect();
  assert.equal(controller.port, null);
  await assert.rejects(controller.welcome({version: 1, profileId: controller.profileId, paired: true, sessionId: 'new', capability: 'new'}), /previous_operation_still_pending/);
  finishClose();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(controller.quarantined, false);
  assert.equal(controller.session, null);
  assert.equal(stored.journal[release.id].state, 'dispatched');
  assert.equal(queries, 0);
});

test('a late Chrome response cannot continue input after its deadline', async () => {
  const controller = await paired(mockChrome(), {operationTimeoutMs: 10});
  await select(controller);
  let finishAttach;
  controller.chrome.debugger.attach = () => new Promise(resolve => { finishAttach = resolve; });
  await assert.rejects(controller.boundedDispatch(request(controller, 'input', {
    action: 'click', ref: 'ref_1', expectedURL: 'https://example.org/', documentToken: 'doc1'
  }, {leaseId: 'lease1'})), /operation_timeout_unknown_outcome/);
  assert.equal(controller.quarantined, true);
  finishAttach();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(controller.quarantined, false);
  assert.equal(controller.session, null);
  assert.ok(!controller.chrome.calls.some(x => x[0] === 'cdp'));
});

test('closing an unowned tab and internal detach callbacks preserve other leases', async () => {
  const controller = await paired();
  await controller.connect();
  await select(controller);
  const generation = controller.generation;
  await controller.detach(999);
  assert.equal(controller.generation, generation);
  assert.equal(controller.leases.size, 1);
  assert.ok(!controller.chrome.calls.some(x => x[0] === 'post' && x[1].event === 'detached'));
  await controller.detach(10);
  assert.equal(controller.leases.size, 0);
  const afterOwned = controller.generation;
  await controller.detach(10);
  assert.equal(controller.generation, afterOwned);
  assert.equal(controller.chrome.calls.filter(x => x[0] === 'post' && x[1].event === 'detached').length, 1);
});


test('opening after the last owned tab closes creates a fresh group without retry', async () => {
  const chrome = mockChrome(), groups = new Set();
  let nextGroup = 100;
  chrome.tabGroups.query = async () => [...groups].map(id => ({id}));
  chrome.tabs.group = async value => {
    chrome.calls.push(['group', value]);
    if (value.groupId !== undefined && !groups.has(value.groupId)) throw new Error('No group with id');
    const id = value.groupId ?? nextGroup++;
    groups.add(id);
    for (const tabId of value.tabIds) chrome.tabsById.get(tabId).groupId = id;
    return id;
  };
  chrome.tabs.remove = async id => {
    chrome.calls.push(['remove', id]);
    const groupId = chrome.tabsById.get(id)?.groupId;
    chrome.tabsById.delete(id);
    if (![...chrome.tabsById.values()].some(tab => tab.groupId === groupId)) groups.delete(groupId);
  };
  const controller = await paired(chrome);
  await controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'first'}));
  const firstGroup = controller.groups.get('chat1');
  await controller.dispatch(request(controller, 'release', {close: true}, {leaseId: 'first'}));
  assert.equal(groups.has(firstGroup), false);
  const second = await controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'second'}));
  assert.equal(second.created, true);
  assert.notEqual(controller.groups.get('chat1'), firstGroup);
  assert.equal(chrome.calls.filter(call => call[0] === 'create').length, 2);
  const groupCalls = chrome.calls.filter(call => call[0] === 'group');
  assert.equal(groupCalls.length, 2);
  assert.equal(groupCalls[1][1].groupId, undefined);
  assert.ok(chrome.tabsById.has(10));
});

test('failed group observation never creates a tab or retries a mutation', async () => {
  const chrome = mockChrome();
  const controller = await paired(chrome);
  controller.groups.set('chat1', 42);
  let queries = 0;
  chrome.tabGroups.query = async () => {queries++; throw new Error('group observation failed');};
  await assert.rejects(controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'failed'})), /group observation failed/);
  assert.equal(queries, 1);
  assert.ok(!chrome.calls.some(call => call[0] === 'create' || call[0] === 'group'));
  assert.equal(controller.groups.get('chat1'), 42);
  assert.ok(chrome.tabsById.has(10));
});


test('an observed existing group is reused on the first grouping attempt', async () => {
  const chrome = mockChrome();
  const controller = await paired(chrome);
  controller.groups.set('chat1', 42);
  await controller.dispatch(request(controller, 'open', {url: 'https://example.org/'}, {leaseId: 'new'}));
  const groups = chrome.calls.filter(call => call[0] === 'group');
  assert.equal(groups.length, 1);
  assert.equal(groups[0][1].groupId, 42);
  assert.equal(chrome.calls.filter(call => call[0] === 'create').length, 1);
});

test('background typing focuses its observed element before inserting text', async () => {
  const controller = await paired(); await select(controller);
  let focused = false, inserted = false;
  const original = controller.chrome.debugger.sendCommand;
  controller.chrome.debugger.sendCommand = async (target, method, params) => {
    if (method === 'Runtime.evaluate' && params.expression.includes('"focus":true')) focused = true;
    if (method === 'Input.insertText') { assert.equal(focused, true); inserted = true; }
    return original(target, method, params);
  };
  await controller.dispatch(request(controller, 'input', {action: 'type', ref: 'ref_1', text: 'hello', expectedURL: 'https://example.org/', documentToken: 'doc1'}, {leaseId: 'lease1'}));
  assert.equal(inserted, true);
});

test('dialog-opening input yields the queue without replay or transport quarantine', async () => {
  const controller = await paired(undefined, {operationTimeoutMs: 100}); await select(controller);
  await controller.dispatch(request(controller, 'read', {}, {leaseId: 'lease1'}));
  let finish, releases = 0;
  const original = controller.chrome.debugger.sendCommand;
  controller.chrome.debugger.sendCommand = async (target, method, params) => {
    if (method === 'Input.dispatchMouseEvent' && params.type === 'mouseReleased') {
      releases++;
      const waiting = new Promise(resolve => { finish = resolve; });
      controller.onDebuggerEvent(target, 'Page.javascriptDialogOpening', {url: 'https://example.org/'});
      return waiting;
    }
    if (method === 'Page.handleJavaScriptDialog') { finish({}); }
    return original(target, method, params);
  };
  const replies = [];
  controller.port = {postMessage: message => replies.push(message)};
  controller.receive(request(controller, 'input', {action: 'click', ref: 'ref_1', expectedURL: 'https://example.org/', documentToken: 'doc1'}, {leaseId: 'lease1'}));
  await controller.queue;
  assert.equal(replies[0].result.dialogPending, true);
  controller.receive(request(controller, 'input', {action: 'dialog', accept: true, expectedURL: 'https://example.org/', documentToken: 'doc1'}, {leaseId: 'lease1'}));
  await controller.queue;
  assert.equal(replies[1].result.handled, true);
  assert.equal(releases, 1);
  assert.equal(controller.quarantined, false);
  assert.equal(controller.dialogWaiters.size, 0);
});


test('input selects only its leased tab; reads stay in the background and failed activation sends no input', async () => {
  const controller = await paired(); await select(controller);
  await controller.dispatch(request(controller, 'read', {}, {leaseId: 'lease1'}));
  assert.equal(controller.chrome.calls.some(c => c[0] === 'update'), false);
  const params = {action: 'click', ref: 'ref_1', expectedURL: 'https://example.org/', documentToken: 'doc1'};
  await controller.dispatch(request(controller, 'input', params, {leaseId: 'lease1'}));
  const calls = controller.chrome.calls;
  const activation = calls.findIndex(c => c[0] === 'update');
  const input = calls.findIndex(c => c[0] === 'cdp' && c[1].startsWith('Input.'));
  assert.deepEqual(calls[activation], ['update', 10, {active: true}]);
  assert.ok(activation < input);
  calls.length = 0;
  controller.chrome.tabsById.get(10).active = false;
  controller.chrome.tabs.update = async () => {throw new Error('activation failed');};
  await assert.rejects(controller.dispatch(request(controller, 'input', params, {leaseId: 'lease1'})), /activation failed/);
  assert.equal(calls.some(c => c[0] === 'cdp' && c[1].startsWith('Input.')), false);
});
