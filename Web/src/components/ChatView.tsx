import { useEffect, useLayoutEffect, useMemo, useRef, useState, type MouseEvent } from 'react'
import { language, t, tx } from '../i18n'
import { s } from '../i18n/strings'
import { commands } from '../protocol/commands'
import { mergeTranscript, type TranscriptMessage } from '../protocol/messages'
import { chatKey, creationKey } from '../protocol/receipts'
import { agentTitle, elapsedSeconds, expiryDate, findProject } from '../protocol/snapshot'
import type { RemoteChat, RemoteCommand, RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import { Composer } from './Composer'
import { DeliveryNotice, Dock } from './Dock'
import type { EngineLike } from './engineLike'
import { commandStatusText, formatDate, formatElapsed, formatRelative, statusTone } from './format'
import { Icon } from './Icon'
import { copyText, renderMarkdown, type ChatLinkRender } from './markdown'
import { pendingCreations } from './selectors'
import { Toolbar } from './Toolbar'
import { useNow } from './useNow'

interface Props {
  engine: EngineLike
  state: EngineState
  device: RemoteDevice
  chatID: string
  onOpen: (id: string) => void
}

export function ChatView({ engine, state, device, chatID, onOpen }: Props) {
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
        <Toolbar title={creation?.text.split('\n')[0].slice(0, 80) || s('newChat')} subtitle={findProject(device, creation?.project)?.name} />
        <div className="transcript-wrap">
          <div className="transcript">
            <div className="column">
              {creation ? (
                <>
                  <Message message={{ id: creation.id, role: 'user', text: creation.text, truncated: false, full: true }} />
                  {creation.status === 'rejected'
                    ? <p className={'status-line ' + statusTone(creation.status)}>{commandStatusText(creation)}</p>
                    : <div className="working-row" role="status"><span className="pulse-dot" aria-hidden="true" /><span className="working-text">{s('chatStarting')}</span></div>}
                </>
              ) : <p className="transcript-note">{s('chatMissing')}</p>}
            </div>
          </div>
        </div>
        {creation && (
          <div className="dock">
            <DeliveryNotice engine={engine} state={state} keyValue={creationKey(device.id, creation.project)} />
          </div>
        )}
      </section>
    )
  }
  return <OpenChat engine={engine} state={state} device={device} chat={chat} onOpen={onOpen} />
}

/** The agent's display name from the chat's model, as the author line of the Mac transcript. */
function agentName(device: RemoteDevice, chat: RemoteChat): string {
  const project = findProject(device, chat.project)
  const id = chat.settings?.options.model
  const model = id ? [...(project?.models ?? []), ...(project?.newChatModels ?? [])].find((value) => value.id === id) : undefined
  return model ? agentTitle(model) : s('agent')
}

function OpenChat({ engine, state, device, chat, onOpen }: { engine: EngineLike; state: EngineState; device: RemoteDevice; chat: RemoteChat; onOpen: (id: string) => void }) {
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
  const author = agentName(device, chat)

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
    const target = event.target as HTMLElement
    const copy = target.closest('button[data-copy]') as HTMLButtonElement | null
    if (copy) {
      event.preventDefault()
      void copyText(copy.closest('.code-block')?.querySelector('pre code')?.textContent ?? '', copy)
      return
    }
    const button = target.closest('button[data-restore]') as HTMLButtonElement | null
    if (!button) return
    event.preventDefault()
    const id = button.dataset.restore
    if (id) void restore(id)
  }

  // Follow the transcript while the reader is at the bottom.
  const scroller = useRef<HTMLDivElement>(null)
  const atBottom = useRef(true)
  const [away, setAway] = useState(false)
  const onScroll = () => {
    const element = scroller.current
    if (!element) return
    atBottom.current = element.scrollHeight - element.scrollTop - element.clientHeight < 80
    setAway(!atBottom.current)
  }
  const lastText = messages.length ? messages[messages.length - 1].text.length + ':' + messages.length : ''
  useLayoutEffect(() => {
    const element = scroller.current
    if (element && atBottom.current) element.scrollTop = element.scrollHeight
  }, [lastText, chat.running, chat.approvals.length, chat.interactions?.length])
  const jump = () => {
    const element = scroller.current
    if (element) element.scrollTo({ top: element.scrollHeight, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })
  }

  const restoreErrors = Object.keys(restoring).flatMap((id) => {
    const error = state.chatErrors[chatKey(device.id, id)]
    return error ? [tx(error)] : []
  })
  const loading = web?.loading && !web.messages && (chat.webMessages ?? 0) > chat.messages.length

  return (
    <section className="chat">
      <Toolbar title={chat.title || s('newChat')} subtitle={project?.name}>
        {detail && <span className="toolbar-detail">{detail}</span>}
      </Toolbar>
      <div className="transcript-wrap">
        <div className="transcript" ref={scroller} onScroll={onScroll} onClick={onTranscriptClick}>
          <div className="column">
            {web?.messages && web.messages.length >= 500 && <p className="transcript-note">{s('olderOnMac')}</p>}
            {loading && <p className="transcript-note" role="status"><span className="pulse-dot" aria-hidden="true" /> {s('loadingMessages')}</p>}
            {web?.error && <p className="transcript-note error">{tx(web.error)}</p>}
            {messages.length === 0 && !loading && <p className="transcript-note">{s('emptyChat')}</p>}
            {messages.map((message, index) => (
              <Message key={message.id} message={message} links={linkRender}
                author={message.role !== 'user' && (index === 0 || messages[index - 1].role === 'user') ? author : null} />
            ))}
            {restoreErrors.map((error, index) => <p key={index} className="transcript-note error">{error}</p>)}
            {chat.running && <WorkingRow chat={chat} />}
          </div>
        </div>
        {away && (
          <button type="button" className="jump-button" onClick={jump} aria-label={s('jumpToLatest')} title={s('jumpToLatest')}>
            <Icon name="arrowDown" />
          </button>
        )}
      </div>
      <Dock engine={engine} state={state} device={device} chat={chat}>
        <Composer engine={engine} state={state} device={device} chat={chat} />
      </Dock>
    </section>
  )
}

/** The last row of the transcript while the agent works: pulsing dot, latest activity, elapsed time. */
function WorkingRow({ chat }: { chat: RemoteChat }) {
  const now = useNow(1000, chat.running)
  const elapsed = elapsedSeconds(chat, now)
  return (
    <div className="working-row" role="status">
      <span className="pulse-dot" aria-hidden="true" />
      <span className="working-text">{chat.activity || s('agentWorking')}</span>
      {elapsed !== null && <span className="working-time" aria-hidden="true">{formatElapsed(elapsed)}</span>}
    </div>
  )
}

function Message({ message, links = null, author = null }: { message: TranscriptMessage; links?: ChatLinkRender | null; author?: string | null }) {
  const user = message.role === 'user'
  // Link and copy labels change with the restore state and the language; the HTML is rebuilt when they do.
  const labels = links ? collectLabels(message.text, links).join('|') : ''
  const lang = language()
  const html = useMemo(() => (user ? '' : renderMarkdown(message.text, links)), [user, message.text, labels, links === null, lang])
  const [copied, setCopied] = useState(false)
  const copy = () => {
    void navigator.clipboard?.writeText(message.text).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    }, () => {})
  }
  return (
    <article className={'message ' + (user ? 'user' : 'assistant')}>
      <h3 className="sr-only">{user ? s('you') : author ?? s('agent')}</h3>
      {author && (
        <div className="author" aria-hidden="true">
          <span className="author-badge"><Icon name="sparkle" size={11} /></span>
          <span className="author-name">{author}</span>
        </div>
      )}
      {user ? <div className="bubble">{message.text}</div> : <div className="markdown" dangerouslySetInnerHTML={{ __html: html }} />}
      {message.truncated && <div className="message-note">{s('messageTruncated')}</div>}
      <div className="message-tools">
        <button type="button" className="icon-button small" onClick={copy} aria-label={copied ? s('copied') : s('copyMessage')} title={copied ? s('copied') : s('copyMessage')}>
          <Icon name={copied ? 'check' : 'copy'} size={14} />
        </button>
      </div>
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
