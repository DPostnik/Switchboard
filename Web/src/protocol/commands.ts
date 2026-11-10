// Command construction and validation, mirroring RemoteCommand in MobileRemote.swift.
// A command ID is generated once; the row is immutable once stored.
import type { RemoteChatOptions, RemoteCommand, RemoteInteraction } from './types'

export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isUUID(value: string | null | undefined): value is string {
  return typeof value === 'string' && uuidPattern.test(value)
}

export function newCommandID(): string {
  return crypto.randomUUID().toLowerCase()
}

export const limits = {
  textBytes: 32_000,
  turnBytes: 500,
  chatLength: 500,
  modelBytes: 200,
  roleBytes: 200,
  addOnLimit: 8,
  addOnBytes: 64,
  questionLimit: 8,
  answerBytes: 8000,
  answerKeyBytes: 8000,
  answersTotalBytes: 24_000,
  searchCharacters: 2000,
} as const

/** Kinds that bring a message to the agent; the cloud queue runs them one at a time per chat. */
export const messageKinds = new Set(['send', 'create', 'queue', 'interrupt', 'search'])
export const kinds = new Set([
  'send', 'stop', 'allow', 'deny', 'create', 'configure', 'file', 'answer', 'queue', 'interrupt', 'restore', 'search',
])

const encoder = new TextEncoder()
export function utf8Length(value: string): number {
  return encoder.encode(value).length
}

export class InvalidCommandError extends Error {
  constructor(reason: string) {
    super(reason)
    this.name = 'InvalidCommandError'
  }
}

export class InvalidAnswerError extends Error {
  constructor(reason: string) {
    super(reason)
    this.name = 'InvalidAnswerError'
  }
}

interface Base {
  owner: string
  device: string
  project: string
}

function make(base: Base, chat: string, kind: string, fields: Partial<RemoteCommand> = {}, id = newCommandID()): RemoteCommand {
  return { id, owner: base.owner, device: base.device, project: base.project, chat, kind, text: '', status: 'pending', ...fields }
}

/** The web chat ID reserved by a `create` or `search` command. */
export function webChatID(commandID: string): string {
  return 'web:' + commandID.toLowerCase()
}

/** True when the command's own ID names the chat it creates. */
export function createsChat(command: Pick<RemoteCommand, 'id' | 'chat' | 'kind'>): boolean {
  const id = command.id.toLowerCase()
  return ['send', 'create', 'search'].includes(command.kind) && (command.chat === 'mobile:' + id || command.chat === 'web:' + id)
}

export const commands = {
  /** A message to an idle chat. Carries the observed turn, as the phone does. */
  send(base: Base, chat: string, text: string, turn?: string | null): RemoteCommand {
    return make(base, chat, 'send', { text, turn: turn ?? null })
  },
  /** Stops the observed running turn. */
  stop(base: Base, chat: string, turn?: string | null): RemoteCommand {
    return make(base, chat, 'stop', { turn: turn ?? null })
  },
  allow(base: Base, chat: string, approval: string, turn?: string | null): RemoteCommand {
    return make(base, chat, 'allow', { approval, turn: turn ?? null })
  },
  /** Declines an approval, or a form / link / unsupported request (`RemoteInteraction.canDecline`). */
  deny(base: Base, chat: string, approval: string, turn?: string | null): RemoteCommand {
    return make(base, chat, 'deny', { approval, turn: turn ?? null })
  },
  /** Joins the chat's desktop queue (`RemoteChat.canQueue`). */
  queue(base: Base, chat: string, text: string): RemoteCommand {
    return make(base, chat, 'queue', { text })
  },
  /** Stops the observed `turn` and sends the message next (`RemoteChat.canInterrupt`). */
  interrupt(base: Base, chat: string, turn: string, text: string): RemoteCommand {
    return make(base, chat, 'interrupt', { text, turn })
  },
  /** Answers a question or form with the exact request handle it was published with. */
  answer(base: Base, chat: string, interaction: string, answers: Record<string, string>): RemoteCommand {
    return make(base, chat, 'answer', { approval: interaction, answers })
  },
  /** A new web chat: the chat ID is `web:<command id>`. */
  create(base: Base, text: string, options: RemoteChatOptions): RemoteCommand {
    const id = newCommandID()
    const clean: RemoteChatOptions = { model: options.model }
    if (options.role) clean.role = options.role
    return make(base, webChatID(id), 'create', { text, settings: { options: clean } }, id)
  },
  /** Starts an archive search chat on the Mac; its answers carry `switchboard-chat:` links. */
  search(base: Base, text: string): RemoteCommand {
    const id = newCommandID()
    return make(base, webChatID(id), 'search', { text }, id)
  },
  /** Brings an existing app chat back to the web. */
  restore(base: Base, chat: string): RemoteCommand {
    return make(base, chat, 'restore')
  },
}

function fail(reason: string): never {
  throw new InvalidCommandError(reason)
}

function validateOptions(options: RemoteChatOptions | null | undefined): void {
  if (!options || typeof options.model !== 'string') fail('settings.options')
  if (!options.model || utf8Length(options.model) > limits.modelBytes) fail('model')
  if (options.role != null && (!options.role || utf8Length(options.role) > limits.roleBytes)) fail('role')
  if (options.addOns != null) {
    const addOns = options.addOns
    if (addOns.length > limits.addOnLimit || new Set(addOns).size !== addOns.length
      || !addOns.every((id) => id.length > 0 && utf8Length(id) <= limits.addOnBytes)) fail('addOns')
  }
}

/** Client-side mirror of `RemoteCommand.validate()` plus the web kinds. Throws `InvalidCommandError`. */
export function validateCommand(command: RemoteCommand): void {
  const { kind, text, approval, turn, settings, answers } = command
  if (!isUUID(command.id) || !isUUID(command.project) || !isUUID(command.device)) fail('identity')
  if (!command.owner) fail('owner')
  if (!command.chat || command.chat.length > limits.chatLength) fail('chat')
  if (utf8Length(text) > limits.textBytes) fail('text too long')
  if (!kinds.has(kind)) fail('kind')
  if (command.status !== 'pending') fail('status')
  if (messageKinds.has(kind) && text.trim() === '' && !command.photos?.length) fail('empty message')
  if (['allow', 'deny', 'answer'].includes(kind) && !isUUID(approval)) fail('approval')
  if (turn != null && utf8Length(turn) > limits.turnBytes) fail('turn')
  const photos = command.photos ?? []
  if (photos.length > 4 || (photos.length > 0 && !messageKinds.has(kind)) || new Set(photos.map(p => p.id)).size !== photos.length) fail('photos')
  for (const photo of photos) {
    if (!isUUID(photo.id) || !/^[A-Za-z0-9+/]+={0,2}$/.test(photo.data) || photo.data.length % 4 !== 0 || photo.data.length > 699052) fail('photo')
    const bytes = atob(photo.data)
    if (bytes.length > 524288 || !bytes.startsWith('\xff\xd8\xff')) fail('photo')
  }
  if (kind === 'answer') {
    if (!answers || text !== '' || turn != null || settings != null) fail('answer')
    const entries = Object.entries(answers)
    if (entries.length > limits.questionLimit) fail('answers count')
    let total = 0
    for (const [key, value] of entries) {
      if (typeof value !== 'string' || !key || utf8Length(key) > limits.answerKeyBytes || utf8Length(value) > limits.answerBytes) fail('answer value')
      total += utf8Length(key) + utf8Length(value)
    }
    if (total > limits.answersTotalBytes) fail('answers size')
  } else if (answers != null) fail('answers')
  if (kind === 'interrupt' && !turn) fail('interrupt turn')
  if ((kind === 'queue' || kind === 'interrupt') && approval != null) fail('approval')
  if (kind === 'file') {
    if (text.trim() === '' || text.includes('\n') || text.includes('\0') || approval != null || turn != null || settings != null) fail('file')
  }
  if (kind === 'create' || kind === 'configure') {
    if (!settings || approval != null || turn != null) fail('settings')
    validateOptions(settings.options)
    if (kind === 'create') {
      if (!createsChat(command) || settings.expected != null || settings.expectedProjectAccess != null) fail('create')
    } else {
      if (text !== '' || !settings.expected || settings.expectedProjectAccess == null) fail('configure')
      if (settings.options.addOns != null && settings.expected.addOns == null) fail('configure addOns')
      validateOptions(settings.expected)
    }
  } else if (settings != null) fail('settings')
  if (kind === 'search') {
    // The cloud accepts a search request of 1 to 2000 characters (trimmed).
    if (!createsChat(command) || !command.chat.startsWith('web:') || approval != null || turn != null
      || [...text.trim()].length > limits.searchCharacters) fail('search')
  }
  if (kind === 'restore') {
    // Any existing app chat ID, including an expired web chat's `web:` ID.
    if (text !== '' || approval != null || turn != null) fail('restore')
  }
}

/** The row inserted into `remote_commands`: null and absent fields are omitted. */
export function commandRow(command: RemoteCommand): Record<string, unknown> {
  const row: Record<string, unknown> = {}
  for (const key of ['id', 'owner', 'device', 'project', 'chat', 'kind', 'text', 'approval', 'turn', 'status', 'settings', 'answers', 'photos'] as const) {
    const value = command[key]
    if (value !== null && value !== undefined) row[key] = value
  }
  return row
}

/** Mirror of `RemoteInteraction.validate(answers:)`. Throws `InvalidAnswerError`. */
export function validateAnswers(interaction: RemoteInteraction, answers: Record<string, string>): void {
  const kind = interaction.kind
  if (!interaction.canAnswer || (kind !== 'questions' && kind !== 'form')) throw new InvalidCommandError('not answerable')
  const ids = new Set(interaction.questions.map((question) => question.id))
  const keys = Object.keys(answers)
  if (!keys.every((key) => ids.has(key))) throw new InvalidAnswerError('unknown question')
  if (kind === 'questions' && (keys.length !== ids.size)) throw new InvalidAnswerError('every question')
  for (const question of interaction.questions) {
    const value = Object.prototype.hasOwnProperty.call(answers, question.id) ? answers[question.id] : undefined
    const blank = (value ?? '').trim() === ''
    if (question.required && blank) throw new InvalidAnswerError('required')
    if (value !== undefined && (utf8Length(value) > limits.answerBytes || value.includes('\0'))) throw new InvalidAnswerError('value')
    if (value !== undefined && !blank && !question.allowsOther && question.options.length > 0
      && !question.options.some((option) => option.label === value)) throw new InvalidAnswerError('option')
  }
}

export function isValidAnswers(interaction: RemoteInteraction, answers: Record<string, string>): boolean {
  try {
    validateAnswers(interaction, answers)
    return true
  } catch {
    return false
  }
}
