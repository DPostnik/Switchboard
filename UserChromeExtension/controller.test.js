import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {Controller, validateFiles, validateInput, keyEvents, jpegSize, websiteURL} from './controller.js';
globalThis.crypto ||= webcrypto;
const event = () => ({addListener() {}});
// A minimal JPEG header: SOI and a baseline start-of-frame marker with the given size.
function jpeg(width, height) {
  const bytes = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 3, 0, 0, 0, 0];
  return Buffer.from(bytes).toString('base64');
}
function mockChrome(stored = {}) {
  const calls = [], tabs = new Map([[10, {id: 10, url: 'https://example.org/', title: 'Existing'}]]);
  const chrome = {
    calls, tabsById: tabs, page: {}, viewport: {pageX: 0, pageY: 0, clientWidth: 800, clientHeight: 600}, jpeg: jpeg(800, 600),
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
        if (method === 'Runtime.evaluate') {
          const name = params.expression.match(/^\(function (\w+)/)?.[1];
          const base = {url: tabs.get(target.tabId).url, documentToken: 'doc1', x: 30, y: 40};
          const page = chrome.page[name];
          return {result: {value: typeof page === 'function' ? page(JSON.parse(params.expression.slice(params.expression.lastIndexOf(')(') + 2, -1)), params) : {...base, ...page}}};
        }
        if (method === 'Page.getLayoutMetrics') return {cssVisualViewport: {...chrome.viewport}};
        if (method === 'Page.captureScreenshot') return {data: chrome.jpeg};
        if (method === 'DOM.getFrameOwner') return {backendNodeId: 7};
        if (method === 'DOM.getBoxModel') return {model: {content: [100, 200, 500, 200, 500, 500, 100, 500]}};
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

test('rename publishes Unicode metadata without reconnecting or revoking leases', async () => {
  const chrome = mockChrome();
  const controller = await paired(chrome);
  await controller.connect();
  await select(controller);
  const session = controller.session;
  const port = controller.port;
  await controller.rename(' Даниил Посник ');
  assert.equal(controller.status().profileName, 'Даниил Посник');
  assert.equal((await chrome.storage.local.get()).profileName, 'Даниил Посник');
  assert.deepEqual(chrome.calls.at(-1), ['post', {type: 'event', event: 'profileRenamed', profileName: 'Даниил Посник'}]);
  assert.equal(controller.port, port);
  assert.equal(controller.session, session);
  assert.equal(controller.leases.size, 1);
});

const observed = {expectedURL: 'https://example.org/', documentToken: 'doc1'};
const inputs = calls => calls.filter(c => c[0] === 'cdp' && c[1].startsWith('Input.')).map(c => c[2]);
async function shot(controller) {
  return controller.dispatch(request(controller, 'screenshot', {}, {leaseId: 'lease1'}));
}

test('input arguments are validated before Chrome is touched', () => {
  for (const bad of [
    {action: 'click'}, {action: 'click', ref: 'ref_1', x: 1, y: 2}, {action: 'click', x: 1}, {action: 'click', ref: 'button'},
    {action: 'hover', x: 1, y: 2}, {action: 'type', text: ''}, {action: 'type', text: 'a', x: 1, y: 2},
    {action: 'key', key: 'F13'}, {action: 'key', key: 'cmd+cmd+a'}, {action: 'key', key: 'Enter;rm'},
    {action: 'scroll', deltaY: 0}, {action: 'scroll', deltaY: 9000}, {action: 'scroll_to'},
    {action: 'set_value', ref: 'ref_1'}, {action: 'set_value', ref: 'ref_1', value: 'a', checked: true}
  ]) assert.throws(() => validateInput(bad), undefined, JSON.stringify(bad));
  for (const good of [
    {action: 'click', ref: 'ref_1'}, {action: 'click', x: 10, y: 20}, {action: 'triple_click', x: 0, y: 0},
    {action: 'type', text: 'hi'}, {action: 'key', key: 'shift+Tab'}, {action: 'key', key: 'cmd+a'},
    {action: 'scroll', deltaY: 300}, {action: 'scroll', x: 5, y: 5, deltaY: -300}, {action: 'set_value', ref: 'ref_2', checked: false}
  ]) assert.doesNotThrow(() => validateInput(good), JSON.stringify(good));
});

test('key chords follow the closed list with CDP modifiers and editing commands', () => {
  const [down, up] = keyEvents('cmd+a');
  assert.equal(down.type, 'rawKeyDown');
  assert.equal(down.modifiers, 4);
  assert.deepEqual(down.commands, ['selectAll']);
  assert.equal(up.type, 'keyUp');
  assert.equal(keyEvents('shift+Tab')[0].modifiers, 8);
  assert.equal(keyEvents('Enter')[0].text, '\r');
  assert.equal(keyEvents('shift+a')[0].text, 'A');
  assert.equal(keyEvents('ctrl+c')[0].text, undefined);
  assert.equal(keyEvents('F5'), null);
});

test('screenshot reports its pixel size, document and viewport; JPEG size is read from the image', async () => {
  assert.deepEqual(jpegSize(jpeg(1280, 720)), {width: 1280, height: 720});
  assert.equal(jpegSize('AA=='), null);
  const controller = await paired(); await select(controller);
  controller.chrome.page.pageInfo = {devicePixelRatio: 2};
  controller.chrome.viewport = {pageX: 0, pageY: 0, clientWidth: 1600, clientHeight: 1000};
  controller.chrome.jpeg = jpeg(1280, 800);
  const result = await shot(controller);
  assert.equal(result.width, 1280);
  assert.equal(result.height, 800);
  assert.equal(result.documentToken, 'doc1');
  assert.deepEqual(result.viewport, {width: 1600, height: 1000});
  const capture = controller.chrome.calls.find(c => c[1] === 'Page.captureScreenshot')[2];
  assert.equal(capture.clip.scale, 1280 / (1600 * 2));
});

test('coordinate click maps screenshot pixels to CSS pixels and needs a current screenshot', async () => {
  const controller = await paired(); await select(controller);
  const click = {action: 'click', x: 640, y: 400, ...observed};
  await assert.rejects(controller.dispatch(request(controller, 'input', click, {leaseId: 'lease1'})), /screenshot_required/);
  controller.chrome.viewport = {pageX: 0, pageY: 0, clientWidth: 1600, clientHeight: 1000};
  controller.chrome.jpeg = jpeg(1280, 800);
  await shot(controller);
  controller.chrome.calls.length = 0;
  const result = await controller.dispatch(request(controller, 'input', click, {leaseId: 'lease1'}));
  assert.equal(result.performed, 'click');
  const events = inputs(controller.chrome.calls);
  assert.deepEqual(events.map(e => e.type), ['mouseMoved', 'mousePressed', 'mouseReleased']);
  assert.equal(events[1].x, 800);
  assert.equal(events[1].y, 500);
  // Scrolling moves what lies under the pixels: the old screenshot no longer maps.
  controller.chrome.viewport = {...controller.chrome.viewport, pageY: 300};
  controller.chrome.calls.length = 0;
  await assert.rejects(controller.dispatch(request(controller, 'input', click, {leaseId: 'lease1'})), /screenshot_stale/);
  await assert.rejects(controller.dispatch(request(controller, 'input', {...click, y: 900}, {leaseId: 'lease1'})), /screenshot_stale|coordinates_outside/);
  assert.equal(inputs(controller.chrome.calls).length, 0);
});

test('coordinate click refuses sensitive fields and file inputs under the point', async () => {
  const controller = await paired(); await select(controller);
  await shot(controller);
  controller.chrome.calls.length = 0;
  for (const [page, error] of [[{found: true, sensitive: true}, /sensitive_input/], [{found: true, file: true}, /file_input_use_upload/]]) {
    controller.chrome.page.inspectPoint = page;
    await assert.rejects(controller.dispatch(request(controller, 'input', {action: 'click', x: 10, y: 10, ...observed}, {leaseId: 'lease1'})), error);
  }
  assert.equal(inputs(controller.chrome.calls).length, 0);
});

test('double, triple and right clicks send counted presses', async () => {
  const controller = await paired(); await select(controller);
  for (const [action, button, counts] of [['double_click', 'left', [1, 2]], ['triple_click', 'left', [1, 2, 3]], ['right_click', 'right', [1]]]) {
    controller.chrome.calls.length = 0;
    await controller.dispatch(request(controller, 'input', {action, ref: 'ref_1', ...observed}, {leaseId: 'lease1'}));
    const presses = inputs(controller.chrome.calls).filter(e => e.type === 'mousePressed');
    assert.deepEqual(presses.map(e => e.clickCount), counts);
    assert.ok(presses.every(e => e.button === button));
  }
});

test('typing without a ref goes to a verified, non-sensitive focused field', async () => {
  const controller = await paired(); await select(controller);
  const type = {action: 'type', text: 'hello', ...observed};
  controller.chrome.page.inspectFocus = {focused: true, crossFrame: false, sensitive: true, editable: true};
  await assert.rejects(controller.dispatch(request(controller, 'input', type, {leaseId: 'lease1'})), /sensitive_input/);
  controller.chrome.page.inspectFocus = {focused: false};
  await assert.rejects(controller.dispatch(request(controller, 'input', type, {leaseId: 'lease1'})), /no_focused_element/);
  controller.chrome.page.inspectFocus = {focused: true, crossFrame: true};
  await assert.rejects(controller.dispatch(request(controller, 'input', type, {leaseId: 'lease1'})), /focused_element_unverified/);
  assert.equal(inputs(controller.chrome.calls).length, 0);
  controller.chrome.page.inspectFocus = {focused: true, crossFrame: false, sensitive: false, editable: true};
  await controller.dispatch(request(controller, 'input', type, {leaseId: 'lease1'}));
  assert.deepEqual(inputs(controller.chrome.calls), [{text: 'hello'}]);
});

test('scroll goes to a point or the viewport centre, never a fixed corner', async () => {
  const controller = await paired(); await select(controller);
  await controller.dispatch(request(controller, 'input', {action: 'scroll', deltaY: 300, ...observed}, {leaseId: 'lease1'}));
  const wheel = inputs(controller.chrome.calls).find(e => e.type === 'mouseWheel');
  assert.deepEqual([wheel.x, wheel.y, wheel.deltaY], [400, 300, 300]);
});

test('input by ref inside a frame is offset by the frame position', async () => {
  const controller = await paired(); await select(controller);
  const original = controller.chrome.debugger.sendCommand;
  controller.chrome.debugger.sendCommand = async (target, method, params) => method === 'Page.getFrameTree'
    ? {frameTree: {frame: {id: 'frame1', url: 'https://example.org/'}, childFrames: [{frame: {id: 'child', url: 'https://forms.example.org/'}}]}}
    : original(target, method, params);
  await controller.dispatch(request(controller, 'input', {action: 'click', ref: 'ref_1', frameId: 'child', ...observed}, {leaseId: 'lease1'}));
  const press = inputs(controller.chrome.calls).find(e => e.type === 'mousePressed');
  assert.deepEqual([press.x, press.y], [130, 240]);
  await assert.rejects(controller.dispatch(request(controller, 'input', {action: 'click', x: 1, y: 1, frameId: 'child', ...observed}, {leaseId: 'lease1'})), /coordinates_are_tab_pixels/);
});

test('set_value clicks a checkbox only when its state differs and selects options by label', async () => {
  const controller = await paired(); await select(controller);
  controller.chrome.page.resolveElement = {checked: true, type: 'checkbox'};
  const same = await controller.dispatch(request(controller, 'input', {action: 'set_value', ref: 'ref_1', checked: true, ...observed}, {leaseId: 'lease1'}));
  assert.equal(same.unchanged, true);
  assert.equal(inputs(controller.chrome.calls).length, 0);
  await controller.dispatch(request(controller, 'input', {action: 'set_value', ref: 'ref_1', checked: false, ...observed}, {leaseId: 'lease1'}));
  assert.equal(inputs(controller.chrome.calls).filter(e => e.type === 'mousePressed').length, 1);
  controller.chrome.page.resolveElement = {checked: true, type: 'radio'};
  await assert.rejects(controller.dispatch(request(controller, 'input', {action: 'set_value', ref: 'ref_1', checked: false, ...observed}, {leaseId: 'lease1'})), /radio_cannot_be_unchecked/);
  controller.chrome.page.selectOption = {selected: 'Poland'};
  const chosen = await controller.dispatch(request(controller, 'input', {action: 'set_value', ref: 'ref_3', value: 'Poland', ...observed}, {leaseId: 'lease1'}));
  assert.equal(chosen.selected, 'Poland');
});

test('a zoomed screenshot keeps the full screenshot mapping', async () => {
  const controller = await paired(); await select(controller);
  controller.chrome.viewport = {pageX: 0, pageY: 0, clientWidth: 1600, clientHeight: 1000};
  controller.chrome.jpeg = jpeg(1280, 800);
  await shot(controller);
  const zoom = await controller.dispatch(request(controller, 'screenshot', {clip: {x: 100, y: 100, width: 200, height: 100}}, {leaseId: 'lease1'}));
  assert.deepEqual(zoom.zoom, {x: 100, y: 100, width: 200, height: 100});
  const capture = controller.chrome.calls.filter(c => c[1] === 'Page.captureScreenshot').at(-1)[2];
  assert.deepEqual([capture.clip.x, capture.clip.y, capture.clip.width, capture.clip.height], [125, 125, 250, 125]);
  assert.equal(controller.shots.get(10).imageWidth, 1280);
  await assert.rejects(controller.dispatch(request(controller, 'screenshot', {clip: {x: 1200, y: 0, width: 200, height: 10}}, {leaseId: 'lease1'})), /clip_outside_screenshot/);
  await assert.rejects(controller.dispatch(request(controller, 'screenshot', {waitSeconds: 60}, {leaseId: 'lease1'})), /invalid_wait_seconds/);
});
