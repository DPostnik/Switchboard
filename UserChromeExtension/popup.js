const t = (key, substitutions) => chrome.i18n.getMessage(key, substitutions) || key;
document.documentElement.lang = chrome.i18n.getUILanguage();
for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = t(element.dataset.i18n);
const send = message => chrome.runtime.sendMessage(message);
let nameDirty = false;
let leaseList = '';
const releasing = new Set();
const releaseButtons = new Map();
document.querySelector('#name').addEventListener('input', () => { nameDirty = true; });
const feedback = key => { document.querySelector('#feedback').textContent = t(key); };
async function refresh(state) {
  state ||= await send({type: 'status'});
  const timeout = ['operation_timeout_unknown_outcome', 'previous_operation_still_pending'].includes(state.error);
  document.querySelector('#status').textContent = timeout ? t('operationTimedOut') : state.error ? t('connectionError') : t(state.paired ? 'paired' : state.connected ? 'pairRequired' : 'disconnected');
  document.querySelector('#pairing').hidden = state.paired || !state.connected;
  document.querySelector('#next').hidden = !state.paired;
  document.querySelector('#connect').hidden = state.connected && !state.error;
  document.querySelector('#code').textContent = state.pairingCode || '';
  document.querySelector('#profile').textContent = `${t('profileIdentity')}: ${state.profileId || ''}`;
  const input = document.querySelector('#name');
  if (!nameDirty && document.activeElement !== input) input.value = state.profileName || '';
  const leases = state.leases || [];
  document.querySelector('#managed').hidden = !leases.length;
  const signature = JSON.stringify(leases.map(({leaseId, title}) => [leaseId, title]));
  if (signature === leaseList) return;
  leaseList = signature;
  const list = document.querySelector('#leases');
  list.replaceChildren();
  releaseButtons.clear();
  for (const {leaseId, title} of leases) {
    const row = document.createElement('li');
    const name = document.createElement('span');
    name.className = 'lease-title';
    name.textContent = title?.trim() || t('untitledTab');
    name.title = name.textContent;
    const button = document.createElement('button');
    button.className = 'release';
    button.textContent = t('releaseTab');
    button.setAttribute('aria-label', t('releaseNamedTab', name.textContent));
    button.disabled = releasing.has(leaseId);
    releaseButtons.set(leaseId, button);
    button.addEventListener('click', async () => {
      if (releasing.has(leaseId)) return;
      releasing.add(leaseId);
      button.disabled = true;
      try { await action({type: 'release-tab', leaseId}); }
      finally {
        releasing.delete(leaseId);
        const currentButton = releaseButtons.get(leaseId);
        if (currentButton) currentButton.disabled = false;
      }
    });
    row.append(name, button);
    list.append(row);
  }
}
async function action(message) {
  try {
    const state = await send(message);
    await refresh(state);
    if (message.type === 'rename' && !state.error) { nameDirty = false; feedback('nameSaved'); }
  }
  catch { document.querySelector('#status').textContent = t('connectionError'); }
}
document.querySelector('#stop').addEventListener('click', () => action({type: 'stop'}));
document.querySelector('#connect').addEventListener('click', () => action({type: 'connect'}));
document.querySelector('#save').addEventListener('click', () => action({type: 'rename', name: document.querySelector('#name').value}));
document.querySelector('#copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(document.querySelector('#code').textContent);
    feedback('codeCopied');
  } catch { feedback('copyFailed'); }
});
void refresh().catch(() => feedback('connectionError'));
setInterval(() => { void refresh().catch(() => feedback('connectionError')); }, 2000);
