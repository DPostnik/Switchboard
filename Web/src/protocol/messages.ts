// Transcript of a web chat: full text from `remote_web_messages`, completed by the snapshot's
// clipped messages that the Mac has not written to the table yet (live streamed text).
import type { RemoteMessage, WebMessage } from './types'

export interface TranscriptMessage {
  id: string
  role: string
  text: string
  /** The text was cut (by the 100,000-character cloud limit, or the snapshot's 2,000-character limit). */
  truncated: boolean
  /** Full text from the web message table. */
  full: boolean
}

/** Sorts by `seq` and drops duplicate IDs (the later row wins). */
export function normalizeWebMessages(rows: WebMessage[]): WebMessage[] {
  const byID = new Map<string, WebMessage>()
  for (const row of rows) if (row && typeof row.id === 'string') byID.set(row.id, row)
  return [...byID.values()].sort((a, b) => a.seq - b.seq)
}

export function mergeTranscript(full: WebMessage[] | null | undefined, snapshot: RemoteMessage[]): TranscriptMessage[] {
  const fromSnapshot = (message: RemoteMessage): TranscriptMessage => ({
    id: message.id, role: message.role, text: message.text, truncated: message.truncated === true, full: false,
  })
  if (!full || full.length === 0) return snapshot.map(fromSnapshot)
  const latest = new Map(snapshot.map((message) => [message.id, message]))
  const result: TranscriptMessage[] = normalizeWebMessages(full).map((row) => {
    const live = latest.get(row.id)
    // Streaming may run ahead of the table: a complete, longer snapshot text wins.
    if (live && live.truncated !== true && live.text.length > row.text.length) return fromSnapshot(live)
    return { id: row.id, role: row.role, text: row.text, truncated: row.truncated === true, full: true }
  })
  const known = new Set(result.map((message) => message.id))
  for (const message of snapshot) if (!known.has(message.id)) result.push(fromSnapshot(message))
  return result
}
