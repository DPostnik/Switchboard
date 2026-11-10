import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type RefObject } from 'react'
import { preparePhoto } from '../protocol/photos'
import type { RemotePhoto } from '../protocol/types'
import { s } from '../i18n/strings'
import { commands, limits, utf8Length } from '../protocol/commands'
import { chatKey } from '../protocol/receipts'
import { findProject } from '../protocol/snapshot'
import type { RemoteChat, RemoteCommand, RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import type { EngineLike } from './engineLike'
import { commandStatusText, statusTone } from './format'
import { Icon } from './Icon'
import { latestOwnCommand } from './selectors'

/** Drafts survive switching chats within the tab. */
const drafts = new Map<string, string>()

const photoDrafts = new Map<string, RemotePhoto[]>()

type Action = 'send' | 'queue' | 'interrupt'

/** Grows a text field with its content up to the Mac composer's cap. */
export function useAutosize(field: RefObject<HTMLTextAreaElement | null>, value: string, max = 220): void {
  useLayoutEffect(() => {
    const element = field.current
    if (!element) return
    element.style.height = 'auto'
    element.style.height = Math.min(element.scrollHeight, max) + 'px'
    element.style.overflowY = element.scrollHeight > max ? 'auto' : 'hidden'
  }, [field, value, max])
}

export function Composer({ engine, state, device, chat }: { engine: EngineLike; state: EngineState; device: RemoteDevice; chat: RemoteChat }) {
  const key = chatKey(device.id, chat.id)
  const [draft, setDraftState] = useState(() => drafts.get(key) ?? '')
  const setDraft = (value: string) => {
    drafts.set(key, value)
    setDraftState(value)
  }
  const [photos, setPhotosState] = useState<RemotePhoto[]>(() => photoDrafts.get(key) ?? [])
  const [loadingPhotos, setLoadingPhotos] = useState(false)
  const [photoError, setPhotoError] = useState(false)
  const choosing = useRef(false)
  const picker = useRef<HTMLInputElement>(null)
  const setPhotos = (value: RemotePhoto[]) => { photoDrafts.set(key, value); setPhotosState(value) }
  const addPhotos = async (files: File[]) => {
    if (choosing.current || engine.isBlocked(key)) return
    choosing.current = true
    setLoadingPhotos(true)
    setPhotoError(false)
    try {
      if (files.length + photos.length > 4) throw new Error('count')
      const added: RemotePhoto[] = []
      for (const file of files) added.push(await preparePhoto(file))
      setPhotos([...photos, ...added])
    } catch { setPhotoError(true) }
    finally { choosing.current = false; setLoadingPhotos(false) }
  }
  const input = useRef<HTMLTextAreaElement>(null)
  useEffect(() => {
    input.current?.focus()
  }, [key])
  useAutosize(input, draft)

  if (chat.readOnly) return <div className="banner neutral"><Icon name="lock" /><span>{s('readOnly')}</span></div>

  const blocked = engine.isBlocked(key)
  const sending = state.inFlight.has(key)
  const hasText = draft.trim() !== '' || photos.length > 0
  const tooLong = utf8Length(draft) > limits.textBytes
  const canQueue = chat.running && chat.canQueue === true
  const canInterrupt = chat.running && chat.canInterrupt === true && Boolean(chat.turn)
  const primary: Action | null = !chat.running ? 'send' : canQueue ? 'queue' : canInterrupt ? 'interrupt' : null
  // One round control, as on the Mac: stop while a response runs and nothing can be sent, otherwise send or queue.
  const stops = chat.running && (!hasText || !primary)
  const base = { owner: engine.owner, device: device.id, project: chat.project }

  const submit = async (action: Action) => {
    const text = draft
    if (blocked || loadingPhotos || !hasText || tooLong) return
    const sentPhotos = photos
    const command = await engine.perform(() => {
      const build = () => {
      switch (action) {
        case 'queue': return commands.queue(base, chat.id, text)
        case 'interrupt': return commands.interrupt(base, chat.id, chat.turn ?? '', text)
        default: return commands.send(base, chat.id, text, chat.turn)
      }
      }
      const value = build()
      if (sentPhotos.length) value.photos = sentPhotos
      return value
    })
    if (command && photoDrafts.get(key) === sentPhotos) setPhotos([])
    // The draft clears only after the queue holds the command, and only if unchanged meanwhile.
    if (command && (drafts.get(key) ?? '') === text) setDraft('')
  }
  const stop = () => void engine.perform(() => commands.stop(base, chat.id, chat.turn))

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== 'Enter' || event.shiftKey || event.nativeEvent.isComposing || event.altKey) return
    event.preventDefault()
    if (primary) void submit(primary)
  }

  const hint = primary === 'queue' ? s('queueHint') : primary === 'interrupt' ? s('interruptHint') : s('sendHint')
  const sendLabel = primary === 'queue' ? s('queue') : primary === 'interrupt' ? s('interruptAndSend') : s('send')
  return (
    <div className="composer-area">
      <CommandLine state={state} device={device} chat={chat} />
      {chat.running && !primary && hasText && <div className="composer-note">{s('busyNoQueue')}</div>}
      {tooLong && <div className="composer-note bad" role="alert">{s('textTooLong')}</div>}
      {photoError && <div role="alert" className="composer-note bad">{s('photoError')}</div>}
      {photos.length > 0 && <div className="photo-strip">{photos.map(photo => <button type="button" key={photo.id} disabled={blocked || loadingPhotos} aria-label={s('removePhoto')} onClick={() => setPhotos(photos.filter(p => p.id !== photo.id))}><img src={'data:image/jpeg;base64,' + photo.data} alt={s('attachedPhoto')} /></button>)}</div>}
      <div className="composer">
        <textarea ref={input} className="composer-input" value={draft} rows={1}
          placeholder={chat.running && primary ? s('queuePlaceholder') : s('messagePlaceholder')}
          onChange={(event) => setDraft(event.target.value)} onKeyDown={onKeyDown} disabled={blocked} aria-label={s('message')} />
        <div className="composer-bar">
          {chat.supportsPhotos === true && <>
            <input ref={picker} type="file" accept="image/*" multiple hidden onChange={event => { void addPhotos(Array.from(event.target.files ?? [])); event.target.value = '' }} />
            <button type="button" className="chip-button" disabled={blocked || loadingPhotos || photos.length >= 4} onClick={() => picker.current?.click()}>{s(loadingPhotos ? 'preparingPhotos' : 'attachPhotos')}</button>
          </>}
          <ChatChips device={device} chat={chat} />
          <span className="composer-spacer" />
          {canInterrupt && canQueue && hasText && (
            <button type="button" className="chip-button" onClick={() => void submit('interrupt')} disabled={blocked || loadingPhotos || tooLong}>
              <Icon name="interrupt" size={13} />
              <span>{s('interruptAndSend')}</span>
            </button>
          )}
          {stops ? (
            <button type="button" className="round-button" onClick={stop} disabled={blocked} aria-label={s('stopResponse')} title={s('stopResponse')}>
              <Icon name="stop" size={11} />
            </button>
          ) : (
            <button type="button" className="round-button" onClick={() => primary && void submit(primary)} disabled={blocked || loadingPhotos || !hasText || tooLong || !primary}
              aria-label={sendLabel} title={hint} aria-busy={sending || undefined}>
              <Icon name="arrowUp" size={15} />
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

/** The chat's role and model, shown like the Mac composer's chips. They change only on the Mac. */
function ChatChips({ device, chat }: { device: RemoteDevice; chat: RemoteChat }) {
  const settings = chat.settings
  if (!settings) return null
  const project = findProject(device, chat.project)
  const modelID = settings.options.model
  const model = [...(project?.models ?? []), ...(project?.newChatModels ?? [])].find((value) => value.id === modelID)
  const roleID = settings.options.role ?? settings.projectRole
  const role = (settings.roles ?? []).find((value) => value.id === roleID)
  const full = (settings.options.access ?? settings.projectAccess) === 'fullAccess'
  const hint = s('chipReadOnly')
  return (
    <>
      {role && (
        <span className="chip" title={(full ? s('accessFull') : s('accessStandard')) + ' · ' + hint}>
          <Icon name={full ? 'lockOpen' : 'lock'} size={13} label={full ? s('accessFull') : s('accessStandard')} />
          <span className="ellipsis">{role.name}</span>
        </span>
      )}
      {modelID && (
        <span className="chip" title={hint}>
          <Icon name="sparkle" size={12} />
          <span className="ellipsis">{model?.name ?? modelID}</span>
        </span>
      )}
    </>
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
  return <div className={'composer-note status-line ' + statusTone(command.status)} role="status">{commandStatusText(command)}</div>
}
