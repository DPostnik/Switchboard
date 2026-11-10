const t = (key, substitutions) => chrome.i18n.getMessage(key, substitutions) || key;
document.documentElement.lang = chrome.i18n.getUILanguage();
for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = t(element.dataset.i18n);
const send = message => chrome.runtime.sendMessage(message);
async function refresh(state) {
  state ||= await send({type: 'status'});
  const timeout = ['operation_timeout_unknown_outcome', 'previous_operation_still_pending'].includes(state.error);
  document.querySelector('#status').textContent = timeout ? t('operationTimedOut') : state.error ? t('connectionError') : t(state.paired ? 'paired' : state.connected ? 'pairRequired' : 'disconnected');
  document.querySelector('#pairing').hidden = state.paired || !state.connected;
  document.querySelector('#code').textContent = state.pairingCode || '';
  document.querySelector('#profile').textContent = `${t('profileIdentity')}: ${state.profileId || ''}`;
  const input = document.querySelector('#name');
  if (document.activeElement !== input) input.value = state.profileName || '';
  const list = document.querySelector('#leases'); list.replaceChildren();
  for (const lease of state.leases || []) {
    const li = document.createElement('li');
    li.textContent = t('lease', [lease.chatId, String(lease.tabId)]);
    list.append(li);
  }
  document.querySelector('#stop').disabled = !(state.leases || []).length;
}
async function action(message) {
  try { await refresh(await send(message)); }
  catch { document.querySelector('#status').textContent = t('connectionError'); }
}
document.querySelector('#stop').addEventListener('click', () => action({type: 'stop'}));
document.querySelector('#connect').addEventListener('click', () => action({type: 'connect'}));
document.querySelector('#save').addEventListener('click', () => action({type: 'rename', name: document.querySelector('#name').value}));
void refresh();
setInterval(() => { void refresh(); }, 2000);
