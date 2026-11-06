import { t } from '../i18n'
import { s } from '../i18n/strings'
import { expiryDate, webChats } from '../protocol/snapshot'
import type { RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import { formatDate, formatRelative } from './format'
import { pendingCreations } from './selectors'
import { useNow } from './useNow'
import type { View } from './Workspace'

interface Props {
  state: EngineState
  device: RemoteDevice | undefined
  projectFilter: string
  onProjectFilter: (id: string) => void
  view: View
  onView: (view: View) => void
}

export function Sidebar({ state, device, projectFilter, onProjectFilter, view, onView }: Props) {
  const now = useNow(60_000)
  if (!device) return <aside className="sidebar" />
  const projects = device.snapshot.projects
  const chats = webChats(device, projectFilter || null)
  const pending = pendingCreations(state, device).filter((command) => !projectFilter || command.project.toLowerCase() === projectFilter.toLowerCase())
  const canCreate = projects.some((project) => project.canUseWeb === true && project.canCreateChat !== false)
  const canSearch = projects.some((project) => project.canUseWeb === true && project.canSearchChats === true)
  const anyWeb = projects.some((project) => project.canUseWeb === true)
  const lastActive = state.lastActive[device.id] ?? {}
  const projectName = (id: string) => projects.find((project) => project.id.toLowerCase() === id.toLowerCase())?.name ?? ''
  const selected = view.kind === 'chat' ? view.id : null

  return (
    <aside className="sidebar">
      <label className="field compact">
        <span>{s('project')}</span>
        <select value={projectFilter} onChange={(event) => onProjectFilter(event.target.value)}>
          <option value="">{s('allProjects')}</option>
          {projects.map((project) => <option key={project.id} value={project.id}>{project.name}</option>)}
        </select>
      </label>
      <div className="sidebar-actions">
        <button type="button" className={'primary' + (view.kind === 'new' ? ' active' : '')} disabled={!canCreate} onClick={() => onView({ kind: 'new' })}>{s('newChat')}</button>
        {canSearch && <button type="button" className={view.kind === 'search' ? 'active' : ''} onClick={() => onView({ kind: 'search' })}>{s('findInArchive')}</button>}
      </div>
      {!anyWeb && state.synced && <p className="notice small">{s('noWebSupport')}</p>}
      <div className="list-title small muted">{s('webChats')}</div>
      <nav className="chat-list" aria-label={s('webChats')}>
        {pending.map((command) => (
          <button type="button" key={command.id} className={'chat-item' + (selected === command.chat ? ' selected' : '')} onClick={() => onView({ kind: 'chat', id: command.chat })}>
            <span className="chat-item-title">{command.text.split('\n')[0].slice(0, 80) || s('newChat')}</span>
            <span className="chat-item-meta small muted">{s('starting')}</span>
          </button>
        ))}
        {chats.map((chat) => {
          const active = lastActive[chat.id]
          const expiry = expiryDate(active)
          return (
            <button type="button" key={chat.id} className={'chat-item' + (selected === chat.id ? ' selected' : '')} onClick={() => onView({ kind: 'chat', id: chat.id })} aria-current={selected === chat.id ? 'page' : undefined}>
              <span className="chat-item-title">
                {chat.running && <span className="dot run" aria-label={s('running')} />}
                <span className="ellipsis">{chat.title || s('newChat')}</span>
                {chat.chatSearch === true && <span className="badge">{s('searchBadge')}</span>}
                {(chat.approvals.length > 0 || (chat.interactions ?? []).length > 0) && <span className="badge warn">!</span>}
              </span>
              <span className="chat-item-meta small muted">
                {!projectFilter && <span className="ellipsis">{projectName(chat.project)}</span>}
                {active && <span>{formatRelative(active, now)}</span>}
                {expiry && <span title={t('Удалится из облака', 'Leaves the cloud')}>{t(`до ${formatDate(expiry)}`, `until ${formatDate(expiry)}`)}</span>}
              </span>
            </button>
          )
        })}
        {chats.length === 0 && pending.length === 0 && <p className="muted small empty-list">{s('noWebChats')}</p>}
      </nav>
    </aside>
  )
}
