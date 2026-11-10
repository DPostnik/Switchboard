import {Controller} from './controller.js';
const controller = new Controller(chrome);
const ready = controller.initialize().then(() => controller.connect());
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'reconnect') void ready.then(() => controller.connect()); });
chrome.runtime.onStartup.addListener(() => { void ready.then(() => controller.connect()); });
chrome.debugger.onDetach.addListener(source => { if (source.tabId) void ready.then(() => controller.detach(source.tabId)); });
chrome.tabs.onRemoved.addListener(tabId => { void ready.then(() => controller.detach(tabId)); });
chrome.debugger.onEvent.addListener((source, method, params) => controller.onDebuggerEvent(source, method, params));
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  // Only our own popup can change pairing identity or stop execution.
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return false;
  void ready.then(async () => {
    if (message?.type === 'status') return controller.status();
    if (message?.type === 'stop') return controller.stop();
    if (message?.type === 'connect') { await controller.connect(); return controller.status(); }
    if (message?.type === 'rename' && typeof message.name === 'string' && message.name.trim().length <= 80) {
      controller.profileName = message.name.trim() || 'Chrome';
      await chrome.storage.local.set({profileName: controller.profileName});
      return controller.status();
    }
    throw new Error('unsupported_popup_action');
  }).then(reply, error => reply({error: error.code || error.message}));
  return true;
});
