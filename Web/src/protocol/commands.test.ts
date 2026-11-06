import { describe, expect, it } from 'vitest'
import { classifyInsert } from './api'
import { InvalidAnswerError, InvalidCommandError, commandRow, commands, createsChat, isUUID, validateAnswers, validateCommand } from './commands'
import type { RemoteCommand, RemoteInteraction } from './types'

const base = { owner: '6f1c2a3b-0000-4000-8000-000000000001', device: '0a1b2c3d-1111-4222-8333-444455556666', project: 'A1B2C3D4-0000-4000-8000-0000000000AA' }
const approval = '11111111-2222-4333-8444-555555555555'

function invalid(command: RemoteCommand) {
  expect(() => validateCommand(command)).toThrow(InvalidCommandError)
}

describe('command construction', () => {
  it('creates a web chat whose ID is the command ID', () => {
    const command = commands.create(base, 'Hello', { model: 'gpt-5', role: 'developer' })
    expect(isUUID(command.id)).toBe(true)
    expect(command.id).toBe(command.id.toLowerCase())
    expect(command.chat).toBe('web:' + command.id)
    expect(command.kind).toBe('create')
    expect(command.status).toBe('pending')
    expect(command.settings).toEqual({ options: { model: 'gpt-5', role: 'developer' } })
    expect(createsChat(command)).toBe(true)
    validateCommand(command)
  })

  it('omits an empty role from create settings', () => {
    const command = commands.create(base, 'Hello', { model: 'claude-opus', role: null })
    expect(command.settings).toEqual({ options: { model: 'claude-opus' } })
  })

  it('builds a search chat with no settings', () => {
    const command = commands.search(base, 'the Vercel deploy chat')
    expect(command.chat).toBe('web:' + command.id)
    expect(command.kind).toBe('search')
    expect(command.settings).toBeUndefined()
    validateCommand(command)
  })

  it('restores an existing chat with empty text', () => {
    const command = commands.restore(base, '019a7b2c-desktop-chat')
    expect(command).toMatchObject({ kind: 'restore', chat: '019a7b2c-desktop-chat', text: '' })
    validateCommand(command)
  })

  it('omits null fields from the inserted row', () => {
    const row = commandRow(commands.send(base, 'web:x', 'hi', null))
    expect(Object.keys(row).sort()).toEqual(['chat', 'device', 'id', 'kind', 'owner', 'project', 'status', 'text'])
    const stop = commandRow(commands.stop(base, 'web:x', 'turn-1'))
    expect(stop.turn).toBe('turn-1')
    expect('approval' in stop).toBe(false)
  })

  it('generates a new ID for every command', () => {
    expect(commands.send(base, 'c', 'a').id).not.toBe(commands.send(base, 'c', 'a').id)
  })
})

describe('command validation mirrors RemoteCommand.validate()', () => {
  it('accepts the phone kinds', () => {
    validateCommand(commands.send(base, 'web:a', 'hello', 'turn'))
    validateCommand(commands.stop(base, 'web:a', 'turn'))
    validateCommand(commands.allow(base, 'web:a', approval))
    validateCommand(commands.deny(base, 'web:a', approval))
    validateCommand(commands.queue(base, 'web:a', 'next'))
    validateCommand(commands.interrupt(base, 'web:a', 'turn-7', 'now'))
    validateCommand(commands.answer(base, 'web:a', approval, { q1: 'Yes' }))
  })

  it('rejects empty messages, bad identities and oversize text', () => {
    invalid(commands.send(base, 'web:a', '   '))
    invalid(commands.queue(base, 'web:a', ''))
    invalid(commands.search(base, ' '))
    invalid(commands.send({ ...base, project: 'not-a-uuid' }, 'web:a', 'hi'))
    invalid(commands.send({ ...base, device: 'mac' }, 'web:a', 'hi'))
    invalid(commands.send(base, '', 'hi'))
    invalid(commands.send(base, 'x'.repeat(501), 'hi'))
    invalid(commands.send(base, 'web:a', 'я'.repeat(16_001)))
    validateCommand(commands.send(base, 'web:a', 'я'.repeat(16_000)))
    invalid({ ...commands.send(base, 'web:a', 'hi'), kind: 'delete' })
    invalid({ ...commands.send(base, 'web:a', 'hi'), status: 'claimed' })
  })

  it('requires a UUID approval for allow, deny and answer', () => {
    invalid(commands.allow(base, 'web:a', 'nope'))
    invalid(commands.deny(base, 'web:a', ''))
    invalid(commands.answer(base, 'web:a', 'nope', { a: 'b' }))
  })

  it('requires a turn for interrupt and no approval for queue or interrupt', () => {
    invalid(commands.interrupt(base, 'web:a', '', 'now'))
    invalid({ ...commands.queue(base, 'web:a', 'x'), approval })
    invalid(commands.stop(base, 'web:a', 't'.repeat(501)))
  })

  it('checks answers', () => {
    invalid({ ...commands.answer(base, 'web:a', approval, { a: 'b' }), text: 'x' })
    invalid({ ...commands.answer(base, 'web:a', approval, { a: 'b' }), turn: 't' })
    const many = Object.fromEntries(Array.from({ length: 9 }, (_, index) => ['q' + index, 'a']))
    invalid(commands.answer(base, 'web:a', approval, many))
    invalid(commands.answer(base, 'web:a', approval, { '': 'a' }))
    invalid(commands.answer(base, 'web:a', approval, { q: 'x'.repeat(8001) }))
    const big = Object.fromEntries(Array.from({ length: 4 }, (_, index) => ['q' + index, 'x'.repeat(7000)]))
    invalid(commands.answer(base, 'web:a', approval, big))
    invalid({ ...commands.send(base, 'web:a', 'hi'), answers: { a: 'b' } })
  })

  it('checks create settings and the reserved chat ID', () => {
    const command = commands.create(base, 'Hello', { model: 'm' })
    invalid({ ...command, chat: 'web:other' })
    invalid({ ...command, settings: null })
    invalid({ ...command, settings: { options: { model: '' } } })
    invalid({ ...command, settings: { options: { model: 'm', role: '' } } })
    invalid({ ...command, settings: { options: { model: 'x'.repeat(201) } } })
    invalid({ ...command, settings: { options: { model: 'm' }, expected: { model: 'm' } } })
    invalid({ ...command, turn: 't' })
    validateCommand({ ...command, chat: 'mobile:' + command.id })
    invalid({ ...commands.send(base, 'web:a', 'hi'), settings: { options: { model: 'm' } } })
  })

  it('checks search and restore shapes', () => {
    const search = commands.search(base, 'find')
    invalid({ ...search, chat: 'mobile:' + search.id })
    invalid({ ...search, chat: 'web:' + 'f'.repeat(8) })
    validateCommand({ ...search, text: 'ж'.repeat(2000) })
    invalid({ ...search, text: 'ж'.repeat(2001) })
    invalid({ ...commands.restore(base, 'chat'), text: 'x' })
    invalid({ ...commands.restore(base, 'chat'), approval })
    invalid(commands.restore(base, ''))
  })
})

describe('insert outcome', () => {
  it('never treats an unknown outcome as not stored', () => {
    expect(classifyInsert(201)).toBe('stored')
    expect(classifyInsert(409)).toBe('stored')
    expect(classifyInsert(400)).toBe('notStored')
    expect(classifyInsert(403)).toBe('notStored')
    expect(classifyInsert(408)).toBe('uncertain')
    expect(classifyInsert(0)).toBe('uncertain')
    expect(classifyInsert(500)).toBe('uncertain')
    expect(classifyInsert(503)).toBe('uncertain')
  })
})

describe('answers mirror RemoteInteraction.validate(answers:)', () => {
  const questions: RemoteInteraction = {
    id: approval, kind: 'questions', canAnswer: true, canDecline: false,
    questions: [
      { id: 'color', text: 'Color?', options: [{ label: 'Red' }, { label: 'Blue' }], allowsOther: false, required: true },
      { id: 'note', text: 'Note?', options: [{ label: 'None' }], allowsOther: true, required: false },
    ],
  }

  it('accepts an option label and free text where allowed', () => {
    validateAnswers(questions, { color: 'Red', note: 'anything' })
    validateAnswers(questions, { color: 'Blue', note: '' })
  })

  it('needs every question of a questions request', () => {
    expect(() => validateAnswers(questions, { color: 'Red' })).toThrow(InvalidAnswerError)
  })

  it('rejects unknown keys, other text without allowsOther, blank required answers', () => {
    expect(() => validateAnswers(questions, { color: 'Red', note: '', extra: 'x' })).toThrow(InvalidAnswerError)
    expect(() => validateAnswers(questions, { color: 'Green', note: '' })).toThrow(InvalidAnswerError)
    expect(() => validateAnswers(questions, { color: '  ', note: '' })).toThrow(InvalidAnswerError)
  })

  it('lets a form leave optional fields out and refuses Mac-only requests', () => {
    const form: RemoteInteraction = { ...questions, kind: 'form' }
    validateAnswers(form, { color: 'Red' })
    expect(() => validateAnswers({ ...questions, canAnswer: false, macOnly: 'secret' }, { color: 'Red', note: '' })).toThrow(InvalidCommandError)
    expect(() => validateAnswers({ ...questions, kind: 'link' }, {})).toThrow(InvalidCommandError)
  })
})
