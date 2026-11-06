import { useEffect, useLayoutEffect, useMemo, useRef, useState, type MouseEvent } from 'react'
import { t, tx } from '../i18n'
import { s } from '../i18n/strings'
import { commands } from '../protocol/commands'
import { mergeTranscript, type TranscriptMessage } from '../protocol/messages'
import { chatKey, creationKey } from '../protocol/receipts'
import { expiryDate, findProject } from '../protocol/snapshot'
import type { RemoteChat, RemoteCommand, RemoteDevice } from '../protocol/types'
import type { Engine, EngineState } from '../sync/engine'
import { Composer } from './Composer'
import { DeliveryNotice, Dock } from './Dock'
import { commandStatusText, formatDate, formatRelative, statusTone } from './format'
import { renderMarkdown, type ChatLinkRender } from './markdown'
import { pendingCreations } from './selectors'

interface Props {
  engine: Engine
  state: EngineState
  device: RemoteDevice
  chatID: string
  onOpen: (id: string) => void
  onBack: () => void
}

export function ChatView({ engine, state, device, chatID, onOpen, onBack }: Props) {
  const chat = device.snapshot.chats.find((value) => value.id === chatID && value.web === true)
  useEffect(() => {
    engine.watch(device.id, chatID)
    return () => engine.watch(null, null)
  }, [engine, device.id, chatID])

  if (!chat) {
    const creation = pendingCreations(state, device).find((command) => command.chat === chatID)
      ?? state.commands.find((command) => command.chat === chatID && state.own.has(command.id))
    return (
      <section className="chat">
        <ChatHeader title={creation?.text.split('\n')[0].slice(0, 80) || s('newChat')} subtitle={findProject(device, creation?.project)?.name} onBack={onBack} />
        <div className="transcript">
          {creation ? (
            <>
              <Message message={{ id: creation.id, role: 'user', text: creation.text, truncated: false, full: true }} />
              <p className={'status-line ' + statusTone(creation.status)}>
                {creation.status === 'rejected' ? commandStatusText(creation) : s('chatStarting')}
              </p>
            </>
          ) : <p className="placeholder muted">{s('chatMissing')}</p>}
        </div>
        {creation && (
          <div className="dock">
            <DeliveryNotice engine={engine} state={state} keyValue={creationKey(device.id, creation.project)} />
          </div>
        )}
      </section>
    )
  }
  return <OpenChat engine={engine} state={state} device={device} chat={chat} onOpen={onOpen} onBack={onBack} />
}

function ChatHeader({ title, subtitle, detail, onBack }: { title: string; subtitle?: string; detail?: string | null; onBack: () => void }) {
  return (
    <div className="chat-header">
      <button type="button" className="ghost small back" onClick={onBack} aria-label={t('Назад к списку', 'Back to the list')}>←</button>
      <div className="chat-header-text">
        <h2 className="ellipsis">{title}</h2>
        <div className="small muted ellipsis">{[subtitle, detail].filter(Boolean).join(' · ')}</div>
      </div>
    </div>
  )
}

function OpenChat({ engine, state, device, chat, onOpen, onBack }: { engine: Engine; state: EngineState; device: RemoteDevice; chat: RemoteChat; onOpen: (id: string) => void; onBack: () => void }) {
  const project = findProject(device, chat.project)
  const key = chatKey(device.id, chat.id)
  const web = state.web[key]
  const messages = useMemo(() => mergeTranscript(web?.messages, chat.messages), [web?.messages, chat.messages])
  const lastActive = state.lastActive[device.id]?.[chat.id]
  const expiry = expiryDate(lastActive)
  const detail = [
    lastActive ? formatRelative(lastActive) : null,
    expiry ? t(`в облаке до ${formatDate(expiry)}`, `in the cloud until ${formatDate(expiry)}`) : null,
  ].filter(Boolean).join(' · ')

  // Archive-search answers: "Open in browser" for each found chat.
  const [restoring, setRestoring] = useState<Record<string, string>>({})
  const restoreCommand = (id: string): RemoteCommand | undefined => {
    const commandID = restoring[id]
    return commandID ? state.commands.find((command) => command.id === commandID) : undefined
  }
  const isWebChat = (id: string) => device.snapshot.chats.some((value) => value.id === id && value.web === true)
  const linkRender: ChatLinkRender | null = chat.chatSearch === true ? {
    label: (id) => {
      if (isWebChat(id)) return s('open')
      if (state.inFlight.has(chatKey(device.id, id))) return s('opening')
      const command = restoreCommand(id)
      if (command?.status === 'rejected' || command?.status === 'uncertain') return s('restoreFailed')
      if (command) return s('opening')
      return s('openInBrowser')
    },
    disabled: (id) => !isWebChat(id) && (state.inFlight.has(chatKey(device.id, id)) || (restoreCommand(id) !== undefined && !['rejected', 'uncertain'].includes(restoreCommand(id)!.status))),
  } : null

  const restore = async (id: string) => {
    if (isWebChat(id)) {
      onOpen(id)
      return
    }
    const command = await engine.perform((owner) => commands.restore({ owner, device: device.id, project: chat.project }, id))
    if (command) setRestoring((value) => ({ ...value, [id]: command.id }))
  }
  const onTranscriptClick = (event: MouseEvent<HTMLDivElement>) => {
    const button = (event.target as HTMLElement).closest('button[data-restore]') as HTMLButtonElement | null
    if (!button) return
    event.preventDefault()
    const id = button.dataset.restore
    if (id) void restore(id)
  }

  // Follow the transcript while the reader is at the bottom.
  const scroller = useRef<HTMLDivElement>(null)
  const atBottom = useRef(true)
  const onScroll = () => {
    const element = scroller.current
    if (element) atBottom.current = element.scrollHeight - element.scrollTop - element.clientHeight < 80
  }
  const lastText = messages.length ? messages[messages.length - 1].text.length + ':' + messages.length : ''
  useLayoutEffect(() => {
    const element = scroller.current
    if (element && atBottom.current) element.scrollTop = element.scrollHeight
  }, [lastText, chat.running, chat.approvals.length, chat.interactions?.length])

  const restoreErrors = Object.keys(restoring).flatMap((id) => {
    const error = state.chatErrors[chatKey(device.id, id)]
    return error ? [tx(error)] : []
  })
  const loading = web?.loading && !web.messages && (chat.webMessages ?? 0) > chat.messages.length

  return (
    <section className="chat">
      <ChatHeader title={chat.title || s('newChat')} subtitle={project?.name} detail={detail} onBack={onBack} />
      <div className="transcript" ref={scroller} onScroll={onScroll} onClick={onTranscriptClick}>
        {web?.messages && web.messages.length >= 500 && <p className="muted small center">{s('olderOnMac')}</p>}
        {loading && <p className="muted small center">{s('loadingMessages')}</p>}
        {web?.error && <p className="error small center">{tx(web.error)}</p>}
        {messages.length === 0 && !loading && <p className="placeholder muted">{s('emptyChat')}</p>}
        {messages.map((message) => <Message key={message.id} message={message} links={linkRender} />)}
        {restoreErrors.map((error, index) => <p key={index} className="error small">{error}</p>)}
      </div>
      <Dock engine={engine} state={state} device={device} chat={chat}>
        <Composer engine={engine} state={state} device={device} chat={chat} />
      </Dock>
    </section>
  )
}

function Message({ message, links = null }: { message: TranscriptMessage; links?: ChatLinkRender | null }) {
  const user = message.role === 'user'
  // Link labels change with the restore state and the language; the HTML is rebuilt when they do.
  const labels = links ? collectLabels(message.text, links).join('|') : ''
  const html = useMemo(() => (user ? '' : renderMarkdown(message.text, links)), [user, message.text, labels, links === null])
  return (
    <article className={'message ' + (user ? 'user' : 'assistant')}>
      <div className="message-role small muted">{user ? s('you') : s('agent')}</div>
      {user ? <div className="message-body plain">{message.text}</div> : <div className="message-body markdown" dangerouslySetInnerHTML={{ __html: html }} />}
      {message.truncated && <div className="small muted">{s('messageTruncated')}</div>}
    </article>
  )
}

/** Labels of the chat links of one message, so its rendering updates when a restore progresses. */
function collectLabels(text: string, links: ChatLinkRender): string[] {
  if (!text.includes('switchboard-chat:')) return []
  const ids = [...text.matchAll(/switchboard-chat:([^)\s>]+)/gi)].map((match) => match[1])
  return ids.map((id) => {
    let decoded = id
    try {
      decoded = decodeURIComponent(id)
    } catch {
      // Keep the raw value.
    }
    return links.label(decoded) + (links.disabled(decoded) ? '1' : '0')
  })
}
