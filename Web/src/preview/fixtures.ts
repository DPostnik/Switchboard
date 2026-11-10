// Dev-only sample data for `?preview=1`: never imported by the production entry.
import { Receipts } from '../protocol/receipts'
import type { RemoteChat, RemoteChatSettings, RemoteDevice, RemoteProject } from '../protocol/types'
import type { EngineState } from '../sync/engine'

export const previewOwner = '00000000-0000-4000-8000-000000000001'
const deviceID = '11111111-1111-4111-8111-111111111111'
const switchboard = '22222222-2222-4222-8222-222222222222'
const wiki = '33333333-3333-4333-8333-333333333333'

const models = [
  { id: 'claude-opus', name: 'Opus 5.5 · High', agent: 'claude' },
  { id: 'claude-sonnet', name: 'Sonnet 5', agent: 'claude' },
  { id: 'gpt-codex', name: 'GPT-5.5 Codex', agent: null },
]
const roles = [
  { id: 'developer', name: 'Developer' },
  { id: 'reviewer', name: 'Reviewer' },
  { id: 'reader', name: 'Read-only' },
]
const settings = (model = 'claude-opus', role = 'developer'): RemoteChatSettings => ({
  options: { model, access: 'standard', role }, projectAccess: 'standard', canEdit: true, projectRole: 'developer', roles,
})
const project = (id: string, name: string, search: boolean): RemoteProject => ({
  id, name, canCreateChat: true, models, newChatModels: models, settings: settings(), canUseWeb: true, canSearchChats: search,
})

const ago = (seconds: number) => new Date(Date.now() - seconds * 1000).toISOString()

const longAnswer = `## Plan for the sync layer

The web client mirrors the phone: it **reads** the published snapshot and **writes** commands into \`remote_commands\`. Nothing runs in the browser.

### Steps

1. Subscribe to the \`remote:<owner>\` channel first, then read, so no change is lost.
2. Apply deltas by revision; an older revision never replaces a newer one.
3. Keep a receipt for every command until the queue reports it.
   - Receipts survive a reload.
   - A receipt blocks only its own chat.

> The Mac stays the only executor. The site never resends a command on its own.

\`\`\`ts
export function applyDelta(delta: RemoteSnapshotDelta, previous: RemoteDevice | undefined): RemoteDevice {
  if (previous && (delta.device.revision ?? 0) < (previous.revision ?? -1)) return previous
  const available = new Map<string, RemoteChat>()
  for (const chat of previous?.snapshot.chats ?? []) available.set(chat.id, chat)
  for (const chat of delta.chats ?? []) available.set(chat.id, chat)
  return { ...delta.device, snapshot: { ...delta.device.snapshot, chats: order(delta, available) } }
}
\`\`\`

| Table | Retention | Written by | Rows |
|---|---|---|---:|
| \`remote_devices\` | while access is on | Mac | 1 |
| \`remote_commands\` | 7 days | site, phone | 1,284 |
| \`remote_web_messages\` | 15 days | Mac | 12,906 |

#### Checks

- [x] Delta order matches the Swift tests
- [ ] Load test with 500 messages

See the [Supabase Realtime docs](https://supabase.com/docs/guides/realtime) for channel limits.`

const searchAnswer = `Found three chats about the deploy:

- [Vercel deploy for the web client](switchboard-chat:web:44444444-4444-4444-8444-444444444444) — October 30, set up the project and the rewrites.
- [Supabase migration remote_web](switchboard-chat:chat-archived-1) — November 2, 15-day retention.
- [Preview deployments and env keys](switchboard-chat:chat-archived-2) — October 28.

The first one is already open in the browser.`

const chats: RemoteChat[] = [
  {
    id: 'web:44444444-4444-4444-8444-444444444444', project: switchboard, title: 'Редизайн веб-клиента под нативное приложение', running: true, turn: 'turn-1',
    runningSince: ago(95), activity: 'Reading Sources/ContextTranscript/DeskPalette.swift',
    messages: [
      { id: 'm1', role: 'user', text: 'Приведи веб-отображение в порядок в соответствии с нативным macOS-приложением. Сайт открывают в основном с Windows.' },
      { id: 'm2', role: 'assistant', text: 'Сначала изучу палитру `DeskPalette`, боковую панель и ленту сообщений, потом перенесу размеры и цвета в CSS.\n\nПлан:\n\n- цвета и шрифты из кода приложения;\n- светлая и тёмная темы;\n- режим предпросмотра на тестовых данных.' },
    ],
    approvals: [], settings: settings(), web: true, webMessages: 2, canQueue: true, canInterrupt: true,
  },
  {
    id: 'web:55555555-5555-4555-8555-555555555555', project: switchboard, title: 'Install exact dependency versions', running: true, turn: 'turn-2', runningSince: ago(41),
    activity: 'Waiting for approval',
    messages: [
      { id: 'a1', role: 'user', text: 'Add marked 18.1.3 with an exact version and run the tests.' },
      { id: 'a2', role: 'assistant', text: 'I need to run `npm install` with an exact version. It changes `package.json` and `package-lock.json`.' },
    ],
    approvals: [{ id: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', details: '$ npm install --save-exact marked@18.1.3\n\ncwd: ~/Public/self-projects/codex-headroom-client/Web\nreason: add the Markdown renderer with a pinned version', canAllow: true }],
    settings: settings('gpt-codex'), web: true, webMessages: 2, canQueue: true, canInterrupt: true,
  },
  {
    id: 'web:66666666-6666-4666-8666-666666666666', project: switchboard, title: 'Где развернуть превью?', running: true, turn: 'turn-3', runningSince: ago(12),
    messages: [
      { id: 'q1', role: 'user', text: 'Подготовь превью-деплой веб-клиента.' },
      { id: 'q2', role: 'assistant', text: 'Перед деплоем нужно выбрать окружение.' },
    ],
    approvals: [],
    interactions: [{
      id: 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', kind: 'questions', canAnswer: true, canDecline: true,
      questions: [{
        id: 'env', header: 'Deploy', text: 'Which environment should the preview use?', required: true, allowsOther: true,
        options: [
          { label: 'Preview', description: 'A Vercel preview URL with the staging Supabase keys' },
          { label: 'Production', description: 'switchboard web domain, the live Supabase project' },
          { label: 'Local only', description: 'Build and serve on this Mac' },
        ],
      }],
    }],
    settings: settings('claude-sonnet', 'reviewer'), web: true, webMessages: 2,
  },
  {
    id: 'web:77777777-7777-4777-8777-777777777777', project: wiki, title: 'Разбор очереди сообщений', running: true, turn: 'turn-4', runningSince: ago(3725),
    activity: 'Running npx vitest run src/protocol',
    messages: [
      { id: 'w1', role: 'user', text: 'Проверь, как очередь переживает перезапуск приложения.' },
      { id: 'w2', role: 'assistant', text: 'Запускаю тесты протокола и читаю журнал очереди.' },
    ],
    approvals: [],
    queue: [
      { id: 'queue-1', text: 'После тестов обнови CHANGELOG и опиши поведение очереди при перезапуске.', claimed: true },
      { id: 'queue-2', text: 'Добавь тест: сообщение с телефона во время паузы очереди.', command: 'cmd-phone-1' },
      { id: 'queue-3', text: 'И проверь длинные сообщения: больше 32 000 байт должны отклоняться ещё в браузере, до отправки в облако.' },
    ],
    queueCount: 4, canQueue: true, canInterrupt: true, settings: settings(), web: true, webMessages: 2,
  },
  {
    id: 'web:88888888-8888-4888-8888-888888888888', project: switchboard, title: 'Archive search: Vercel deploy', running: false, chatSearch: true,
    messages: [
      { id: 's1', role: 'user', text: 'Find the chat where we set up the Vercel deploy in October' },
      { id: 's2', role: 'assistant', text: searchAnswer },
    ],
    approvals: [], settings: settings('claude-sonnet', 'reader'), web: true, webMessages: 2,
  },
  {
    id: 'web:99999999-9999-4999-8999-999999999999', project: wiki, title: 'Sync layer: deltas, receipts and retention', running: false, supportsPhotos: true,
    messages: [
      { id: 'l1', role: 'user', text: 'Explain how the web client keeps in sync with the Mac, with the code and a table of the cloud tables.' },
      { id: 'l2', role: 'assistant', text: longAnswer },
      { id: 'l3', role: 'user', text: 'Thanks. Keep the 15-day retention.' },
      { id: 'l4', role: 'assistant', text: 'Done: retention stays at **15 days** after the last activity.' },
    ],
    approvals: [], settings: settings(), web: true, webMessages: 4,
  },
]

export const previewDevice: RemoteDevice = {
  id: deviceID, owner: previewOwner, name: 'MacBook Pro', seen: ago(20), projects: [switchboard, wiki], revision: 1,
  snapshot: { version: 1, projects: [project(switchboard, 'switchboard', true), project(wiki, 'super-wiki', false)], chats },
}

export function previewState(): EngineState {
  const lastActive: Record<string, string> = {}
  chats.forEach((chat, index) => { lastActive[chat.id] = ago(60 * (index * 37 + 2)) })
  return {
    connection: 'connected', error: null, synced: true, devices: [previewDevice], commands: [], own: new Set(),
    macs: new Set([deviceID.toLowerCase()]), receipts: new Receipts(), undelivered: new Set(), inFlight: new Set(),
    chatErrors: {}, web: {}, lastActive: { [deviceID]: lastActive }, webTables: true,
  }
}
