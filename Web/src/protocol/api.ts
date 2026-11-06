// REST calls of the remote protocol through supabase-js. Mirrors RemoteAPI in MobileRemote.swift.
// The web only reads state and inserts commands; it never writes snapshots or claims commands.
import type { SupabaseClient } from '@supabase/supabase-js'
import { commandRow, isUUID, validateCommand } from './commands'
import { normalizeWebMessages } from './messages'
import type { RemoteCommand, RemoteDevice, RemoteSnapshotDelta, WebMessage } from './types'

export type RemoteErrorKind = 'signedOut' | 'request' | 'notStored' | 'uncertain' | 'setup' | 'invalid'

export class RemoteError extends Error {
  readonly kind: RemoteErrorKind
  readonly status: number
  constructor(kind: RemoteErrorKind, status = 0, message?: string) {
    super(message ?? `${kind}${status ? ` (${status})` : ''}`)
    this.name = 'RemoteError'
    this.kind = kind
    this.status = status
  }
}

const timeout = 20_000
const commandColumns = 'id,owner,device,project,chat,kind,text,approval,turn,status'

interface Result<T> {
  data: T | null
  error: { message?: string; code?: string } | null
  status: number
}

function check<T>(result: Result<T>): T | null {
  if (result.error || result.status < 200 || result.status >= 300) {
    if (result.status === 401) throw new RemoteError('signedOut', 401)
    throw new RemoteError('request', result.status, result.error?.message)
  }
  return result.data
}

/** How an insert's HTTP status settles the command's fate.
 *  2xx: stored. 409: the ID (primary key) was stored by an earlier attempt.
 *  Other 4xx except 408: the server answered and rolled back, nothing stored.
 *  0 (network, timeout), 408 and 5xx: unknown; never resubmit automatically, read it back by ID. */
export function classifyInsert(status: number): 'stored' | 'notStored' | 'uncertain' {
  if ((status >= 200 && status < 300) || status === 409) return 'stored'
  if (status >= 400 && status < 500 && status !== 408) return 'notStored'
  return 'uncertain'
}

export class RemoteAPI {
  readonly client: SupabaseClient
  constructor(client: SupabaseClient) {
    this.client = client
  }

  private signal(): AbortSignal {
    return AbortSignal.timeout(timeout)
  }

  async owner(): Promise<string> {
    const { data } = await this.client.auth.getSession()
    const id = data.session?.user.id
    if (!id) throw new RemoteError('signedOut')
    return id
  }

  async checkRealtimeSchema(): Promise<void> {
    const result = await this.client.rpc('remote_protocol_version').abortSignal(this.signal())
    if (result.status === 404) throw new RemoteError('setup', 404)
    if (check(result as Result<number>) !== 2) throw new RemoteError('setup')
  }

  async devices(): Promise<RemoteDevice[]> {
    const result = await this.client.from('remote_devices').select('*').limit(20).abortSignal(this.signal())
    return (check(result as Result<RemoteDevice[]>) ?? []).filter((device) => device?.snapshot?.version === 1)
  }

  async changes(device: string, since: number): Promise<RemoteSnapshotDelta | null> {
    if (!isUUID(device)) throw new RemoteError('invalid')
    const result = await this.client.rpc('read_remote_changes', { device_id: device, since_revision: since }).abortSignal(this.signal())
    return check(result as Result<RemoteSnapshotDelta | null>) ?? null
  }

  /** The latest commands of one Mac, newest first. */
  async commands(device: string): Promise<RemoteCommand[]> {
    if (!isUUID(device)) throw new RemoteError('invalid')
    const result = await this.client.from('remote_commands').select(commandColumns)
      .eq('device', device).order('created', { ascending: false }).limit(30).abortSignal(this.signal())
    return check(result as Result<RemoteCommand[]>) ?? []
  }

  async command(id: string): Promise<RemoteCommand | null> {
    if (!isUUID(id)) throw new RemoteError('invalid')
    const result = await this.client.from('remote_commands').select(commandColumns).eq('id', id.toLowerCase()).limit(1).abortSignal(this.signal())
    return (check(result as Result<RemoteCommand[]>) ?? [])[0] ?? null
  }

  /** Inserts a validated command. Throws `notStored` only when the failure proves the queue does not
   *  hold it, `uncertain` when the outcome is unknown. Never retries. */
  async submit(command: RemoteCommand): Promise<void> {
    validateCommand(command)
    // A failure before sending means nothing reached the server.
    try {
      await this.owner()
    } catch (error) {
      throw new RemoteError('notStored', 0, (error as Error).message)
    }
    let status = 0
    let message: string | undefined
    try {
      const result = await this.client.from('remote_commands').insert(commandRow(command)).abortSignal(this.signal())
      status = result.status
      message = result.error?.message
    } catch (error) {
      status = 0
      message = (error as Error).message
    }
    const outcome = classifyInsert(status)
    if (outcome === 'notStored') throw new RemoteError('notStored', status, message)
    if (outcome === 'uncertain') throw new RemoteError('uncertain', status, message)
  }

  /** Full messages of one web chat in order, paginated by 1000 rows. */
  async webMessages(device: string, chat: string): Promise<WebMessage[]> {
    if (!isUUID(device)) throw new RemoteError('invalid')
    const page = 1000
    const rows: WebMessage[] = []
    for (let from = 0; from < 100_000; from += page) {
      const result = await this.client.from('remote_web_messages').select('id,seq,role,text,truncated')
        .eq('device', device).eq('chat', chat).order('seq', { ascending: true }).range(from, from + page - 1).abortSignal(this.signal())
      const batch = check(result as Result<WebMessage[]>) ?? []
      rows.push(...batch)
      if (batch.length < page) break
    }
    return normalizeWebMessages(rows)
  }

  /** Last activity of every web chat of one Mac (chat ID -> ISO date); null when the cloud schema has no web tables. */
  async webChats(device: string): Promise<Record<string, string> | null> {
    if (!isUUID(device)) throw new RemoteError('invalid')
    const result = await this.client.from('remote_web_chats').select('chat,last_active').eq('device', device).limit(1000).abortSignal(this.signal())
    if (result.status === 404) return null
    const rows = check(result as Result<{ chat: string; last_active: string }[]>) ?? []
    return Object.fromEntries(rows.map((row) => [row.chat, row.last_active]))
  }
}
