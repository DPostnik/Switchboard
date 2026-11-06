import type { SupabaseClient } from '@supabase/supabase-js'
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from 'react'
import { tx, type Language } from '../i18n'
import { s } from '../i18n/strings'
import { Engine } from '../sync/engine'
import { ChatView } from './ChatView'
import type { EngineLike } from './engineLike'
import { EmptyState } from './EmptyState'
import { Icon } from './Icon'
import { NewChatForm } from './NewChatForm'
import { SearchForm } from './SearchForm'
import { Sidebar } from './Sidebar'
import { store, stored } from './storage'
import { ShellContext, Toolbar } from './Toolbar'
import { useMediaQuery } from './useMediaQuery'

export type View = { kind: 'none' } | { kind: 'chat'; id: string } | { kind: 'new'; project?: string } | { kind: 'search' }

function parseHash(hash: string): View {
  if (hash === '#/new') return { kind: 'new' }
  if (hash === '#/search') return { kind: 'search' }
  if (hash.startsWith('#/chat/')) {
    try {
      const id = decodeURIComponent(hash.slice('#/chat/'.length))
      if (id) return { kind: 'chat', id }
    } catch {
      // Malformed link: show nothing selected.
    }
  }
  return { kind: 'none' }
}

function hashOf(view: View): string {
  switch (view.kind) {
    case 'chat': return '#/chat/' + encodeURIComponent(view.id)
    case 'new': return '#/new'
    case 'search': return '#/search'
    default: return ''
  }
}

interface Props {
  client: SupabaseClient
  owner: string
  lang: Language
  onToggleLanguage: () => void
}

/** The signed-in workspace: one sync engine for the tab. */
export function Workspace({ client, owner, lang, onToggleLanguage }: Props) {
  const engine = useMemo(() => new Engine(client, owner), [client, owner])
  useEffect(() => {
    engine.start()
    return () => engine.stop()
  }, [engine])

  const signOut = async () => {
    engine.stop()
    // Only this browser's session: the default global scope would also sign out the Mac and the iPhone,
    // which share the owner account.
    await client.auth.signOut({ scope: 'local' })
  }
  return <WorkspaceShell engine={engine} lang={lang} onToggleLanguage={onToggleLanguage} onSignOut={signOut} />
}

/** Narrow windows show the sidebar as a drawer over the content. */
const narrowQuery = '(max-width: 900px)'

interface ShellProps {
  engine: EngineLike
  lang: Language
  onToggleLanguage: () => void
  onSignOut: () => void
}

/** Sidebar and content, as in the Mac app's main window. */
export function WorkspaceShell({ engine, lang, onToggleLanguage, onSignOut }: ShellProps) {
  const state = useSyncExternalStore(engine.subscribe, engine.getState)
  const narrow = useMediaQuery(narrowQuery)
  const [sidebarHidden, setSidebarHidden] = useState(() => stored('switchboard.sidebar') === 'hidden')
  const [drawerOpen, setDrawerOpen] = useState(false)
  const sidebarVisible = narrow ? drawerOpen : !sidebarHidden
  const toggleSidebar = useCallback(() => {
    if (narrow) setDrawerOpen((value) => !value)
    else setSidebarHidden((value) => {
      store('switchboard.sidebar', value ? 'shown' : 'hidden')
      return !value
    })
  }, [narrow])
  useEffect(() => {
    if (!narrow) setDrawerOpen(false)
  }, [narrow])

  const [view, setViewState] = useState<View>(() => parseHash(location.hash))
  useEffect(() => {
    const changed = () => setViewState(parseHash(location.hash))
    window.addEventListener('hashchange', changed)
    return () => window.removeEventListener('hashchange', changed)
  }, [])
  const setView = useCallback((next: View) => {
    const hash = hashOf(next)
    if (hash) location.hash = hash
    else history.replaceState(null, '', location.pathname + location.search)
    setViewState(next)
    setDrawerOpen(false)
  }, [])

  // Escape closes the drawer; it is the only overlay of the workspace. Focus moves into it when it opens.
  useEffect(() => {
    if (!drawerOpen) return
    document.querySelector<HTMLElement>('#sidebar button:not(:disabled)')?.focus()
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      setDrawerOpen(false)
      document.querySelector<HTMLElement>('.toolbar .icon-button')?.focus()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [drawerOpen])

  const [deviceChoice, setDeviceChoice] = useState(() => stored('switchboard.device'))
  const [projectChoice, setProjectChoiceState] = useState(() => stored('switchboard.project'))
  const device = state.devices.find((value) => value.id === deviceChoice) ?? state.devices[0]
  const chooseDevice = (id: string) => {
    store('switchboard.device', id)
    setDeviceChoice(id)
    setView({ kind: 'none' })
  }
  const chooseProject = (id: string) => {
    store('switchboard.project', id)
    setProjectChoiceState(id)
  }
  // The selected project preselects the project of a new chat or search.
  const selectedProject = device?.snapshot.projects.some((project) => project.id === projectChoice) ? projectChoice : ''
  const initialProject = (view.kind === 'new' && view.project) || selectedProject

  let main
  if (!state.synced) main = <Page title={s('appName')}><EmptyState icon="desktop" title={state.error ? tx(state.error) : s('waitingForData')} busy={!state.error} /></Page>
  else if (!device) main = <Page title={s('appName')}><EmptyState icon="desktop" title={s('noMacs')} /></Page>
  else if (view.kind === 'new') main = <NewChatForm key={'new|' + initialProject} engine={engine} state={state} device={device} initialProject={initialProject} onOpen={(id) => setView({ kind: 'chat', id })} onCancel={() => setView({ kind: 'none' })} />
  else if (view.kind === 'search') main = <SearchForm engine={engine} state={state} device={device} initialProject={initialProject} onOpen={(id) => setView({ kind: 'chat', id })} onCancel={() => setView({ kind: 'none' })} />
  else if (view.kind === 'chat') main = <ChatView key={device.id + '|' + view.id} engine={engine} state={state} device={device} chatID={view.id} onOpen={(id) => setView({ kind: 'chat', id })} />
  else {
    const canCreate = device.snapshot.projects.some((project) => project.canUseWeb === true && project.canCreateChat !== false)
    const canSearch = device.snapshot.projects.some((project) => project.canUseWeb === true && project.canSearchChats === true)
    main = (
      <Page title={s('appName')} subtitle={device.name}>
        <EmptyState icon="bubbles" title={s('emptyTitle')} text={s('selectChat')}>
          {canCreate && <button type="button" className="button" onClick={() => setView({ kind: 'new' })}>{s('newChat')}</button>}
          {canSearch && <button type="button" className="button" onClick={() => setView({ kind: 'search' })}>{s('findInArchive')}</button>}
        </EmptyState>
      </Page>
    )
  }

  const shell = useMemo(() => ({ sidebarVisible, toggleSidebar }), [sidebarVisible, toggleSidebar])
  const className = ['app', narrow ? 'narrow' : 'wide', sidebarVisible ? 'sidebar-shown' : 'sidebar-hidden'].join(' ')
  return (
    <ShellContext.Provider value={shell}>
      <div className={className} data-lang={lang}>
        <Sidebar state={state} device={device} selectedProject={selectedProject} onSelectProject={chooseProject} view={view} onView={setView}
          onChooseDevice={chooseDevice} onSignOut={onSignOut} onToggleLanguage={onToggleLanguage} hidden={!sidebarVisible} />
        {narrow && drawerOpen && <div className="scrim" onClick={() => setDrawerOpen(false)} aria-hidden="true" />}
        <main className="main">
          {state.error && state.connection !== 'connected' && state.synced && (
            <div className="banner problem" role="alert">
              <Icon name="warning" />
              <span>{tx(state.error)}</span>
            </div>
          )}
          {main}
        </main>
      </div>
    </ShellContext.Provider>
  )
}

function Page({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <section className="page">
      <Toolbar title={title} subtitle={subtitle} />
      <div className="page-body">{children}</div>
    </section>
  )
}
