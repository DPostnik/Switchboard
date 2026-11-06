import type { SupabaseClient } from '@supabase/supabase-js'
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import type { Language } from '../i18n'
import { s } from '../i18n/strings'
import { Engine } from '../sync/engine'
import { ChatView } from './ChatView'
import { Header } from './Header'
import { NewChatForm } from './NewChatForm'
import { SearchForm } from './SearchForm'
import { Sidebar } from './Sidebar'

export type View = { kind: 'none' } | { kind: 'chat'; id: string } | { kind: 'new' } | { kind: 'search' }

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

function stored(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}

function store(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    // Not persisted in private mode.
  }
}

interface Props {
  client: SupabaseClient
  owner: string
  lang: Language
  onToggleLanguage: () => void
}

export function Workspace({ client, owner, lang, onToggleLanguage }: Props) {
  const engine = useMemo(() => new Engine(client, owner), [client, owner])
  useEffect(() => {
    engine.start()
    return () => engine.stop()
  }, [engine])
  const state = useSyncExternalStore(engine.subscribe, engine.getState)

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
  }, [])

  const [deviceChoice, setDeviceChoice] = useState(() => stored('switchboard.device'))
  const [projectFilter, setProjectFilterState] = useState(() => stored('switchboard.project'))
  const device = state.devices.find((value) => value.id === deviceChoice) ?? state.devices[0]
  const chooseDevice = (id: string) => {
    store('switchboard.device', id)
    setDeviceChoice(id)
    setView({ kind: 'none' })
  }
  const setProjectFilter = (id: string) => {
    store('switchboard.project', id)
    setProjectFilterState(id)
  }
  const filter = device?.snapshot.projects.some((project) => project.id === projectFilter) ? projectFilter : ''

  const signOut = async () => {
    engine.stop()
    // Only this browser's session: the default global scope would also sign out the Mac and the iPhone,
    // which share the owner account.
    await client.auth.signOut({ scope: 'local' })
  }

  let main
  if (!state.synced) main = <div className="placeholder muted">{state.error ? '' : s('waitingForData')}</div>
  else if (!device) main = <div className="placeholder muted">{s('noMacs')}</div>
  else if (view.kind === 'new') main = <NewChatForm engine={engine} state={state} device={device} initialProject={filter} onOpen={(id) => setView({ kind: 'chat', id })} onCancel={() => setView({ kind: 'none' })} />
  else if (view.kind === 'search') main = <SearchForm engine={engine} state={state} device={device} initialProject={filter} onOpen={(id) => setView({ kind: 'chat', id })} onCancel={() => setView({ kind: 'none' })} />
  else if (view.kind === 'chat') main = <ChatView key={device.id + '|' + view.id} engine={engine} state={state} device={device} chatID={view.id} onOpen={(id) => setView({ kind: 'chat', id })} onBack={() => setView({ kind: 'none' })} />
  else main = <div className="placeholder muted">{s('selectChat')}</div>

  return (
    <div className={'app' + (view.kind === 'none' ? '' : ' has-selection')} data-lang={lang}>
      <Header state={state} device={device} onChooseDevice={chooseDevice} onSignOut={signOut} onToggleLanguage={onToggleLanguage} />
      <div className="layout">
        <Sidebar state={state} device={device} projectFilter={filter} onProjectFilter={setProjectFilter} view={view} onView={setView} />
        <main className="main">{main}</main>
      </div>
    </div>
  )
}
