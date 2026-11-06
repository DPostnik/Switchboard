import { t, tx } from '../i18n'
import { s, type StringKey } from '../i18n/strings'
import type { RemoteDevice } from '../protocol/types'
import type { Connection, EngineState } from '../sync/engine'
import { formatRelative } from './format'
import { LanguageToggle } from './LanguageToggle'
import { useNow } from './useNow'

const connectionText: Record<Connection, StringKey> = {
  connecting: 'connConnecting', syncing: 'connSyncing', connected: 'connConnected', retrying: 'connRetrying',
  offline: 'connOffline', signedOut: 'connSignedOut', failed: 'connFailed', stopped: 'connStopped',
}

interface Props {
  state: EngineState
  device: RemoteDevice | undefined
  onChooseDevice: (id: string) => void
  onSignOut: () => void
  onToggleLanguage: () => void
}

export function Header({ state, device, onChooseDevice, onSignOut, onToggleLanguage }: Props) {
  const now = useNow(30_000)
  const online = device ? state.macs.has(device.id.toLowerCase()) : false
  const seen = formatRelative(device?.seen, now)
  const tone = state.connection === 'connected' ? 'ok' : ['failed', 'signedOut', 'offline'].includes(state.connection) ? 'bad' : 'wait'
  return (
    <header className="header">
      <div className="brand">{s('appName')}</div>
      {device && (
        <div className="mac">
          {state.devices.length > 1 ? (
            <select aria-label={s('mac')} value={device.id} onChange={(event) => onChooseDevice(event.target.value)}>
              {state.devices.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
            </select>
          ) : (
            <span className="mac-name">{device.name}</span>
          )}
          <span className={'dot ' + (online ? 'ok' : 'off')} aria-hidden="true" />
          <span className="muted small">
            {online ? s('macOnline') : s('macOffline')}
            {!online && seen ? t(` · был в сети ${seen}`, ` · last seen ${seen}`) : ''}
          </span>
        </div>
      )}
      <div className="header-spacer" />
      <div className={'connection ' + tone} title={state.error ? tx(state.error) : undefined}>
        <span className={'dot ' + tone} aria-hidden="true" />
        <span className="small">{s(connectionText[state.connection])}</span>
      </div>
      {state.error && state.connection !== 'connected' && <span className="small error header-error">{tx(state.error)}</span>}
      <LanguageToggle onToggle={onToggleLanguage} />
      <button type="button" className="ghost small" onClick={onSignOut}>{s('signOut')}</button>
    </header>
  )
}
