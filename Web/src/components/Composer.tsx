import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { s } from '../i18n/strings'
import { commands, limits, utf8Length } from '../protocol/commands'
import { chatKey } from '../protocol/receipts'
import type { RemoteChat, RemoteCommand, RemoteDevice } from '../protocol/types'
import type { Engine, EngineState } from '../sync/engine'
import { commandStatusText, statusTone } from './format'
import { latestOwnCommand } from './selectors'

/** Drafts survive switching chats within the tab. */
const drafts = new Map<string, string>()

type Action = 'send' | 'queue' | 'interrupt'

export function Composer({ engine, state, device, chat }: { engine: Engine; state: EngineState; device: RemoteDevice; chat: RemoteChat }) {
  const key = chatKey(device.id, chat.id)
  const [draft, setDraftState] = useState(() => drafts.get(key) ?? '')
  const setDraft = (value: string) => {
    drafts.set(key, value)
    setDraftState(value)
  }
  const input = useRef<HTMLTextAreaElement>(null)
  useEffect(() => {
    input.current?.focus()
  }, [key])

  if (chat.readOnly) return <div className="notice small">{s('readOnly')}</div>

  const blocked = engine.isBlocked(key)
  const sending = state.inFlight.has(key)
  const hasText = draft.trim() !== ''
  const tooLong = utf8Length(draft) > limits.textBytes
  const canQueue = chat.running && chat.canQueue === true
  const canInterrupt = chat.running && chat.canInterrupt === true && Boolean(chat.turn)
  const primary: Action | null = !chat.running ? 'send' : canQueue ? 'queue' : canInterrupt ? 'interrupt' : null
  const base = { owner: engine.owner, device: device.id, project: chat.project }

  const submit = async (action: Action) => {
    const text = draft
    if (blocked || text.trim() === '' || tooLong) return
    const command = await engine.perform(() => {
      switch (action) {
        case 'queue': return commands.queue(base, chat.id, text)
        case 'interrupt': return commands.interrupt(base, chat.id, chat.turn ?? '', text)
        default: return commands.send(base, chat.id, text, chat.turn)
      }
    })
    // The draft clears only after the queue holds the command, and only if unchanged meanwhile.
    if (command && (drafts.get(key) ?? '') === text) setDraft('')
  }
  const stop = () => void engine.perform(() => commands.stop(base, chat.id, chat.turn))

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing || event.altKey) return
    event.preventDefault()
    if (primary) void submit(primary)
  }

  return (
    <div className="composer">
      <CommandLine state={state} device={device} chat={chat} />
      {chat.running && !primary && hasText && <div className="small muted">{s('busyNoQueue')}</div>}
      {tooLong && <div className="small error">{s('textTooLong')}</div>}
      <div className="composer-row">
        <textarea ref={input} value={draft} rows={Math.min(10, Math.max(2, draft.split('\n').length))}
          placeholder={chat.running && primary ? s('queuePlaceholder') : s('messagePlaceholder')}
          onChange={(event) => setDraft(event.target.value)} onKeyDown={onKeyDown} disabled={blocked} aria-label={s('messagePlaceholder')} />
        <div className="composer-actions">
          {chat.running && <button type="button" className="danger" onClick={stop} disabled={blocked}>{s('stop')}</button>}
          {canInterrupt && canQueue && <button type="button" onClick={() => void submit('interrupt')} disabled={blocked || !hasText || tooLong}>{s('interruptAndSend')}</button>}
          {primary && (
            <button type="button" className="primary" onClick={() => void submit(primary)} disabled={blocked || !hasText || tooLong}>
              {sending ? s('sending') : primary === 'send' ? s('send') : primary === 'queue' ? s('queue') : s('interruptAndSend')}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

/** State of the latest message, stop or reply this tab sent in the chat; fades once delivered. */
function CommandLine({ state, device, chat }: { state: EngineState; device: RemoteDevice; chat: RemoteChat }) {
  const command: RemoteCommand | undefined = latestOwnCommand(state, device.id, chat.id, ['send', 'queue', 'interrupt', 'stop', 'restore', 'create', 'search'])
  const [hidden, setHidden] = useState<string | null>(null)
  const done = command?.status === 'submitted' || command?.status === 'stop_requested'
  useEffect(() => {
    if (!command || !done) return
    const timer = setTimeout(() => setHidden(command.id + command.status), 8000)
    return () => clearTimeout(timer)
  }, [command, done])
  if (!command || hidden === command.id + command.status) return null
  return <div className={'small status-line ' + statusTone(command.status)} role="status">{commandStatusText(command)}</div>
}
