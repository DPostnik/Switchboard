import { useEffect, useState } from 'react'
import type { RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'

/** A problem must last this long before a banner reports it: Presence and the socket flap briefly on every reconnect. */
export const reachabilityGrace = 5000

export type Reachability = 'ok' | 'server' | 'mac'

/** What blocks the path to the Mac right now, without the grace period. Mac Presence is only known while the server is connected. */
export function reachability(state: Pick<EngineState, 'connection' | 'macs' | 'synced'>, device: RemoteDevice | undefined): Reachability {
  if (!state.synced) return 'ok'
  if (['retrying', 'offline', 'failed'].includes(state.connection)) return 'server'
  if (state.connection !== 'connected' || !device) return 'ok'
  return state.macs.has(device.id.toLowerCase()) ? 'ok' : 'mac'
}

/** The reachability problem once it has lasted `reachabilityGrace`; recovery shows at once. */
export function useReachability(state: EngineState, device: RemoteDevice | undefined, grace = reachabilityGrace): Reachability {
  const current = reachability(state, device)
  const [shown, setShown] = useState<Reachability>('ok')
  useEffect(() => {
    if (current === 'ok' || shown !== 'ok') {
      setShown(current)
      return
    }
    const timer = setTimeout(() => setShown(current), grace)
    return () => clearTimeout(timer)
  }, [current, shown, grace])
  // Once a problem is on screen, a change of its kind shows at once.
  if (current === 'ok' || shown === 'ok') return 'ok'
  return current
}
