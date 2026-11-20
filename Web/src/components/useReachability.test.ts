import { describe, expect, it } from 'vitest'
import type { RemoteDevice } from '../protocol/types'
import type { Connection } from '../sync/engine'
import { reachability } from './useReachability'

const device = { id: 'AAAAAAAA-0000-4000-8000-000000000001' } as RemoteDevice
const state = (connection: Connection, macs: string[], synced = true) => ({ connection, macs: new Set(macs), synced })

describe('reachability', () => {
  it('is fine while the Mac is present', () => {
    expect(reachability(state('connected', [device.id.toLowerCase()]), device)).toBe('ok')
  })
  it('reports the Mac when the server is connected and the Mac is absent', () => {
    expect(reachability(state('connected', []), device)).toBe('mac')
  })
  it('reports the server, not the Mac, when the server is unreachable', () => {
    for (const connection of ['retrying', 'offline', 'failed'] as const) expect(reachability(state(connection, []), device)).toBe('server')
  })
  it('says nothing before the first sync, while connecting, signed out or without a Mac', () => {
    expect(reachability(state('connected', [], false), device)).toBe('ok')
    for (const connection of ['connecting', 'syncing', 'signedOut', 'stopped'] as const) expect(reachability(state(connection, []), device)).toBe('ok')
    expect(reachability(state('connected', []), undefined)).toBe('ok')
  })
})
