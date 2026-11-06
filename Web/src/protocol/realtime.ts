// Realtime channel data, mirroring MobileRealtime.swift. Events are invalidations only:
// they say what to read again, never what to execute.
import { isUUID } from './commands'
import type { RemoteInvalidation } from './types'

/** Private channel of one owner; supabase-js prefixes it with `realtime:`. */
export function channelName(owner: string): string {
  return 'remote:' + owner.toLowerCase()
}

/** The web tracks Presence as a phone so the Mac keeps its fast publication cadence. */
export const presenceRole = 'phone'

const entities = new Set(['device', 'command', 'web'])

/** Parses a `changed` broadcast payload; unknown entities and malformed payloads give null. */
export function parseInvalidation(payload: unknown): RemoteInvalidation | null {
  if (!payload || typeof payload !== 'object') return null
  const data = payload as Record<string, unknown>
  const entity = data.entity
  const device = data.device
  if (typeof entity !== 'string' || !entities.has(entity) || typeof device !== 'string' || !isUUID(device)) return null
  const result: RemoteInvalidation = { entity, device: device.toLowerCase() }
  if (typeof data.id === 'string') result.id = data.id.toLowerCase()
  if (typeof data.status === 'string') result.status = data.status
  if (typeof data.chat === 'string') result.chat = data.chat
  if (entity === 'command' && !isUUID(result.id)) return null
  if (entity === 'web' && !result.chat) return null
  return result
}

/** Mac device IDs (lowercased) present on the channel. Presence is advisory, never authorization. */
export function presentMacs(state: Record<string, unknown[]>): Set<string> {
  const macs = new Set<string>()
  for (const metas of Object.values(state ?? {})) {
    for (const meta of Array.isArray(metas) ? metas : []) {
      const value = meta as Record<string, unknown>
      if (value?.role === 'mac' && typeof value.device === 'string') macs.add(value.device.toLowerCase())
    }
  }
  return macs
}
