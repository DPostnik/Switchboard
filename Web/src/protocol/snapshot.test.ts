import { describe, expect, it } from 'vitest'
import { mergeTranscript } from './messages'
import { Receipts, chatKey, creationKey, receiptKey } from './receipts'
import { parseInvalidation, presentMacs } from './realtime'
import { commands } from './commands'
import { applyDelta, changedChats, elapsedSeconds, expiryDate, mergeFetched, newChatModels, newChatRoles, replaceDevice, webChats } from './snapshot'
import type { RemoteChat, RemoteDevice, RemoteSnapshotDelta } from './types'

const deviceID = '0a1b2c3d-1111-4222-8333-444455556666'

function chat(id: string, extra: Partial<RemoteChat> = {}): RemoteChat {
  return { id, project: 'p', title: id, running: false, messages: [], approvals: [], ...extra }
}

function device(revision: number, chats: RemoteChat[]): RemoteDevice {
  return { id: deviceID, owner: 'o', name: 'Mac', seen: '2026-11-06T10:00:00Z', projects: ['p'], revision, snapshot: { version: 1, projects: [], chats } }
}

function delta(revision: number, chats: RemoteChat[], order: string[]): RemoteSnapshotDelta {
  return { device: device(revision, []), chats, order }
}

describe('snapshot delta merge', () => {
  it('overlays changed chats on the previous ones in the published order', () => {
    const previous = device(5, [chat('a', { title: 'old a' }), chat('b')])
    const result = applyDelta(delta(6, [chat('a', { title: 'new a' }), chat('c')], ['c', 'a', 'b']), previous)
    expect(result.revision).toBe(6)
    expect(result.snapshot.chats.map((value) => value.id)).toEqual(['c', 'a', 'b'])
    expect(result.snapshot.chats[1].title).toBe('new a')
  })

  it('drops chats missing from the order and ignores order IDs without a payload', () => {
    const previous = device(5, [chat('a'), chat('b')])
    const result = applyDelta(delta(6, [], ['b', 'ghost']), previous)
    expect(result.snapshot.chats.map((value) => value.id)).toEqual(['b'])
  })

  it('never lets an older revision replace a newer one', () => {
    const previous = device(9, [chat('a', { title: 'newest' })])
    expect(applyDelta(delta(8, [chat('a', { title: 'stale' })], ['a']), previous)).toBe(previous)
  })

  it('applies a first delta without a previous state', () => {
    const result = applyDelta(delta(1, [chat('a')], ['a']), undefined)
    expect(result.snapshot.chats).toHaveLength(1)
  })

  it('replaces, adds and removes devices', () => {
    const one = replaceDevice([], deviceID, delta(1, [chat('a')], ['a']))
    expect(one).toHaveLength(1)
    const two = replaceDevice(one, deviceID, delta(2, [chat('b')], ['a', 'b']))
    expect(two[0].snapshot.chats.map((value) => value.id)).toEqual(['a', 'b'])
    expect(replaceDevice(two, deviceID, null)).toEqual([])
  })

  it('keeps a newer delta state over an older full fetch and filters unknown versions', () => {
    const current = [device(7, [chat('a')])]
    const fetched = [device(6, [])]
    expect(mergeFetched(current, fetched)[0].revision).toBe(7)
    expect(mergeFetched(current, [device(8, [])])[0].revision).toBe(8)
    expect(mergeFetched(current, [{ ...device(8, []), snapshot: { version: 2, projects: [], chats: [] } }])).toEqual([])
  })

  it('reports changed chats', () => {
    const before = device(1, [chat('a'), chat('b')])
    const after = device(2, [chat('a'), chat('b', { running: true }), chat('c')])
    expect([...changedChats(before, after)].sort()).toEqual(['b', 'c'])
  })

  it('lists only web chats, optionally by project', () => {
    const value = device(1, [chat('a', { web: true }), chat('b'), chat('c', { web: true, project: 'q' })])
    expect(webChats(value).map((item) => item.id)).toEqual(['a', 'c'])
    expect(webChats(value, 'Q').map((item) => item.id)).toEqual(['c'])
  })
})

describe('project choices', () => {
  it('prefers new-chat models and falls back to models', () => {
    expect(newChatModels({ id: 'p', name: 'P', models: [{ id: 'a', name: 'A' }] }).map((model) => model.id)).toEqual(['a'])
    expect(newChatModels({ id: 'p', name: 'P', models: [{ id: 'a', name: 'A' }], newChatModels: [{ id: 'b', name: 'B', agent: 'claude' }] }).map((model) => model.id)).toEqual(['b'])
  })

  it('defaults the role to the project role', () => {
    const settings = { options: { model: 'm' }, projectAccess: 'standard' as const, canEdit: true, projectRole: 'dev', roles: [{ id: 'read', name: 'Read' }, { id: 'dev', name: 'Dev' }] }
    expect(newChatRoles({ id: 'p', name: 'P', settings }).defaultRole).toBe('dev')
    expect(newChatRoles({ id: 'p', name: 'P' })).toEqual({ roles: [], defaultRole: null })
  })
})

describe('times', () => {
  it('computes elapsed time only while running', () => {
    const now = Date.parse('2026-11-06T10:01:05Z')
    expect(elapsedSeconds({ running: true, runningSince: '2026-11-06T10:00:00Z' }, now)).toBe(65)
    expect(elapsedSeconds({ running: false, runningSince: '2026-11-06T10:00:00Z' }, now)).toBeNull()
    expect(elapsedSeconds({ running: true, runningSince: 'garbage' }, now)).toBeNull()
  })

  it('expires a web chat 15 days after its last activity', () => {
    expect(expiryDate('2026-11-06T10:00:00Z')?.toISOString()).toBe('2026-11-21T10:00:00.000Z')
    expect(expiryDate(null)).toBeNull()
  })
})

describe('transcript merge', () => {
  it('keeps delivered images when full history replaces snapshot text and when live text advances', () => {
    const image = { id: 'photo', name: 'result.jpg', mimeType: 'image/jpeg', data: 'aW1hZ2U=' }
    const full = [{ id: 'm', seq: 1, role: 'assistant', text: 'full answer', images: [image] }]
    expect(mergeTranscript(full, [{ id: 'm', role: 'assistant', text: 'full' }])[0].images).toEqual([image])
    expect(mergeTranscript(full, [{ id: 'm', role: 'assistant', text: 'full answer and more' }])[0].images).toEqual([image])
    expect(mergeTranscript([{ ...full[0], images: undefined }], [{ id: 'm', role: 'assistant', text: 'full', images: [image], imageError: true }])[0])
      .toMatchObject({ images: [image], imageError: true })
  })

  it('uses full texts and appends newer snapshot messages', () => {
    const full = [{ id: 'm2', seq: 2, role: 'assistant', text: 'full answer' }, { id: 'm1', seq: 1, role: 'user', text: 'question' }]
    const snapshot = [{ id: 'm2', role: 'assistant', text: 'full…', truncated: true }, { id: 'm3', role: 'assistant', text: 'live' }]
    expect(mergeTranscript(full, snapshot).map((message) => [message.id, message.text])).toEqual([['m1', 'question'], ['m2', 'full answer'], ['m3', 'live']])
  })

  it('lets a longer complete streamed text win and falls back to the snapshot', () => {
    const full = [{ id: 'm1', seq: 1, role: 'assistant', text: 'part' }]
    expect(mergeTranscript(full, [{ id: 'm1', role: 'assistant', text: 'part and more' }])[0].text).toBe('part and more')
    expect(mergeTranscript(null, [{ id: 'm1', role: 'user', text: 'x', truncated: true }])[0]).toMatchObject({ truncated: true, full: false })
  })
})

describe('realtime payloads', () => {
  it('parses known invalidations and ignores the rest', () => {
    expect(parseInvalidation({ entity: 'device', device: deviceID.toUpperCase() })).toEqual({ entity: 'device', device: deviceID })
    expect(parseInvalidation({ entity: 'command', device: deviceID, id: 'A1B2C3D4-0000-4000-8000-0000000000AA', status: 'submitted' }))
      .toMatchObject({ id: 'a1b2c3d4-0000-4000-8000-0000000000aa', status: 'submitted' })
    expect(parseInvalidation({ entity: 'web', device: deviceID, chat: 'web:x' })).toMatchObject({ entity: 'web', chat: 'web:x' })
    expect(parseInvalidation({ entity: 'web', device: deviceID })).toBeNull()
    expect(parseInvalidation({ entity: 'command', device: deviceID, id: 'x' })).toBeNull()
    expect(parseInvalidation({ entity: 'exec', device: deviceID })).toBeNull()
    expect(parseInvalidation({ entity: 'device', device: 'mac' })).toBeNull()
    expect(parseInvalidation(null)).toBeNull()
  })

  it('reads Mac presence', () => {
    const macs = presentMacs({ 'mac:X': [{ role: 'mac', device: 'ABC' }], 'phone:y': [{ role: 'phone', device: 'y' }] })
    expect([...macs]).toEqual(['abc'])
  })
})

describe('receipts', () => {
  const base = { owner: 'o', device: deviceID, project: 'A1B2C3D4-0000-4000-8000-0000000000AA' }

  it('blocks only the command chat, or the project for new chats', () => {
    const send = commands.send(base, 'web:a', 'hi')
    const create = commands.create(base, 'hi', { model: 'm' })
    const receipts = new Receipts().record(send).record(create).record(send)
    expect(receipts.commands).toHaveLength(2)
    expect(receipts.blocking(chatKey(deviceID, 'web:a'))?.id).toBe(send.id)
    expect(receipts.blocking(chatKey(deviceID, 'web:b'))).toBeUndefined()
    expect(receiptKey(create)).toBe(creationKey(deviceID, base.project))
    expect(receipts.blocking(creationKey(deviceID, base.project))?.id).toBe(create.id)
  })

  it('resolves known commands and survives a storage round trip', () => {
    const send = commands.send(base, 'web:a', 'hi')
    const receipts = Receipts.parse(new Receipts([send]).serialize())
    expect(receipts.contains(send.id.toUpperCase())).toBe(true)
    const { receipts: next, removed } = receipts.resolve([send.id])
    expect(removed).toEqual([send.id])
    expect(next.serialize()).toBeNull()
    expect(Receipts.parse('not json').commands).toEqual([])
  })
})
