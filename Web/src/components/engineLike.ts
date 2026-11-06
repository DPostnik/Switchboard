import type { Engine } from '../sync/engine'

/** What the workspace views use of the sync engine. The real `Engine` satisfies it; the dev-only preview
 *  supplies an in-memory stand-in that never touches the network. */
export type EngineLike = Pick<Engine,
  'owner' | 'subscribe' | 'getState' | 'watch' | 'perform' | 'isBlocked' | 'checkDelivery' | 'resend' | 'discard' | 'clearError'>
