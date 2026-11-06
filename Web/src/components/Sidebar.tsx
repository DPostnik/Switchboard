import { useState } from 'react'
import { t, tx } from '../i18n'
import { s, type StringKey } from '../i18n/strings'
import { expiryDate, webChats } from '../protocol/snapshot'
import type { RemoteChat, RemoteCommand, RemoteDevice, RemoteProject } from '../protocol/types'
import type { Connection, EngineState } from '../sync/engine'
import { formatDate, formatRelative } from './format'
import { Icon } from './Icon'
import { pendingCreations } from './selectors'
import { useNow } from './useNow'
import type { View } from './Workspace'
import { store, stored } from './storage'

const connectionText: Record<Connection, StringKey> = {
  connecting: 'connConnecting', syncing: 'connSyncing', connected: 'connConnected', retrying: 'connRetrying',
  offline: 'connOffline', signedOut: 'connSignedOut', failed: 'connFailed', stopped: 'connStopped',
}

interface Props {
  state: EngineState
  device: RemoteDevice | undefined
  selectedProject: string
  onSelectProject: (id: string) => void
  view: View
  onView: (view: View) => void
  onChooseDevice: (id: string) => void
  onSignOut: () => void
  onToggleLanguage: () => void
  hidden: boolean
}

const expansionKey = 'switchboard.expanded'

function readExpansion(): Record<string, boolean> {
  try {
    const value = JSON.parse(stored(expansionKey) || '{}') as unknown
    return value && typeof value === 'object' ? value as Record<string, boolean> : {}
  } catch {
    return {}
  }
}

/** The Mac app's sidebar: title, the Mac, page rows, projects with their browser chats, and the bottom dock. */
export function Sidebar({ state, device, selectedProject, onSelectProject, view, onView, onChooseDevice, onSignOut, onToggleLanguage, hidden }: Props) {
  const now = useNow(60_000)
  const [expansion, setExpansion] = useState(readExpansion)
  const projects = device?.snapshot.projects ?? []
  const pending = device ? pendingCreations(state, device) : []
  const canCreate = projects.some((project) => project.canUseWeb === true && project.canCreateChat !== false)
  const canSearch = projects.some((project) => project.canUseWeb === true && project.canSearchChats === true)
  const anyWeb = projects.some((project) => project.canUseWeb === true)
  const lastActive = device ? state.lastActive[device.id] ?? {} : {}
  const selectedChat = view.kind === 'chat' ? view.id : null
  const tone = state.connection === 'connected' ? 'ok' : ['failed', 'signedOut', 'offline'].includes(state.connection) ? 'bad' : 'wait'

  const toggle = (project: RemoteProject, open: boolean) => {
    const next = { ...expansion, [project.id]: !open }
    setExpansion(next)
    store(expansionKey, JSON.stringify(next))
    onSelectProject(project.id)
  }

  return (
    <aside className="sidebar" id="sidebar" aria-hidden={hidden || undefined} inert={hidden || undefined}>
      <div className="sidebar-title">{s('appName')}</div>
      {device && <MacCard state={state} device={device} onChooseDevice={onChooseDevice} />}
      <nav className="sidebar-pages">
        <button type="button" className={'nav-row' + (view.kind === 'new' ? ' selected' : '')} disabled={!canCreate}
          aria-current={view.kind === 'new' ? 'page' : undefined} onClick={() => onView({ kind: 'new' })}>
          <Icon name="compose" />
          <span>{s('newChat')}</span>
        </button>
        {canSearch && (
          <button type="button" className={'nav-row' + (view.kind === 'search' ? ' selected' : '')}
            aria-current={view.kind === 'search' ? 'page' : undefined} onClick={() => onView({ kind: 'search' })}>
            <Icon name="search" />
            <span>{s('findInArchive')}</span>
          </button>
        )}
      </nav>
      {!anyWeb && state.synced && device && <p className="sidebar-notice">{s('noWebSupport')}</p>}
      <div className="sidebar-scroll">
        {device && projects.length > 0 && <div className="section-header">{s('projects')}</div>}
        {device && projects.map((project) => {
          const chats = webChats(device, project.id)
          const creations = pending.filter((command) => command.project.toLowerCase() === project.id.toLowerCase())
          const has = chats.length + creations.length > 0
          const open = expansion[project.id] ?? has
          return (
            <ProjectGroup key={project.id} project={project} chats={chats} creations={creations} open={open}
              selected={selectedProject === project.id} selectedChat={selectedChat} lastActive={lastActive} now={now}
              onToggle={() => toggle(project, open)} onView={onView} />
          )
        })}
      </div>
      <div className="sidebar-dock">
        <button type="button" className="dock-button" onClick={onToggleLanguage} title={s('languageToggleHint')} aria-label={s('languageToggleHint')}>
          <Icon name="globe" />
          <span>{s('languageToggle')}</span>
        </button>
        <button type="button" className="dock-button icon-only" onClick={onSignOut} title={s('signOut')} aria-label={s('signOut')}>
          <Icon name="signOut" />
        </button>
        <span className="dock-status" title={state.error ? tx(state.error) : undefined} role="status">
          <span className={'dot ' + tone} aria-hidden="true" />
          <span className="ellipsis">{s(connectionText[state.connection])}</span>
        </span>
      </div>
    </aside>
  )
}

/** The Mac this site talks to, with its presence; a picker when the account has several. */
function MacCard({ state, device, onChooseDevice }: { state: EngineState; device: RemoteDevice; onChooseDevice: (id: string) => void }) {
  const now = useNow(30_000)
  const online = state.macs.has(device.id.toLowerCase())
  const seen = formatRelative(device.seen, now)
  return (
    <div className="mac-card">
      <Icon name="desktop" className="mac-icon" />
      <div className="mac-text">
        {state.devices.length > 1 ? (
          <select className="mac-select" aria-label={s('mac')} value={device.id} onChange={(event) => onChooseDevice(event.target.value)}>
            {state.devices.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
          </select>
        ) : (
          <span className="mac-name ellipsis">{device.name}</span>
        )}
        <span className="mac-status ellipsis" aria-label={s('macStatus')}>
          <span className={'dot ' + (online ? 'ok' : 'off')} aria-hidden="true" />
          {online ? s('macOnline') : s('macOffline')}
          {!online && seen ? t(` · был в сети ${seen}`, ` · last seen ${seen}`) : ''}
        </span>
      </div>
    </div>
  )
}

interface GroupProps {
  project: RemoteProject
  chats: RemoteChat[]
  creations: RemoteCommand[]
  open: boolean
  selected: boolean
  selectedChat: string | null
  lastActive: Readonly<Record<string, string>>
  now: number
  onToggle: () => void
  onView: (view: View) => void
}

function ProjectGroup({ project, chats, creations, open, selected, selectedChat, lastActive, now, onToggle, onView }: GroupProps) {
  const waiting = chats.some(needsYou)
  const canCreate = project.canUseWeb === true && project.canCreateChat !== false
  const listID = 'project-chats-' + project.id
  return (
    <div className="project-group">
      <div className={'project-row' + (selected && !selectedChat ? ' selected' : '')}>
        <button type="button" className="project-toggle" aria-expanded={open} aria-controls={listID} onClick={onToggle}>
          <Icon name="chevronRight" size={12} className={'chevron' + (open ? ' open' : '')} />
          <Icon name={selected ? 'folderFill' : 'folder'} className="folder-icon" />
          <span className="project-name ellipsis">{project.name}</span>
          {waiting && <span className="dot attention" role="img" aria-label={s('actionRequired')} title={s('actionRequired')} />}
        </button>
        {canCreate && (
          <button type="button" className="row-tool" onClick={() => onView({ kind: 'new', project: project.id })}
            title={t(`Новый чат в проекте ${project.name}`, `New chat in ${project.name}`)} aria-label={t(`Новый чат в проекте ${project.name}`, `New chat in ${project.name}`)}>
            <Icon name="compose" />
          </button>
        )}
      </div>
      {open && (
        <div className="project-chats" id={listID}>
          {creations.map((command) => (
            <button type="button" key={command.id} className={'chat-row' + (selectedChat === command.chat ? ' selected' : '')}
              aria-current={selectedChat === command.chat ? 'page' : undefined} onClick={() => onView({ kind: 'chat', id: command.chat })}>
              <span className="chat-row-title">{command.text.split('\n')[0].slice(0, 80) || s('newChat')}</span>
              <span className="spinner small" role="img" aria-label={s('starting')} title={s('starting')} />
            </button>
          ))}
          {chats.map((chat) => {
            const active = lastActive[chat.id]
            const expiry = expiryDate(active)
            const title = chat.title || s('newChat')
            const meta = [formatRelative(active, now), expiry ? t(`в облаке до ${formatDate(expiry)}`, `in the cloud until ${formatDate(expiry)}`) : null].filter(Boolean).join(' · ')
            return (
              <button type="button" key={chat.id} className={'chat-row' + (selectedChat === chat.id ? ' selected' : '')}
                aria-current={selectedChat === chat.id ? 'page' : undefined} title={meta ? title + '\n' + meta : title}
                onClick={() => onView({ kind: 'chat', id: chat.id })}>
                <span className="chat-row-title">{title}</span>
                {chat.chatSearch === true && <span className="tag">{s('searchBadge')}</span>}
                {needsYou(chat) && <span className="dot attention" role="img" aria-label={s('actionRequired')} />}
                {chat.running && <span className="spinner small" role="img" aria-label={s('running')} />}
              </button>
            )
          })}
          {chats.length === 0 && creations.length === 0 && <div className="project-empty">{s('noChatsInProject')}</div>}
        </div>
      )}
    </div>
  )
}

function needsYou(chat: RemoteChat): boolean {
  return chat.approvals.length > 0 || (chat.interactions ?? []).length > 0
}
