import { createsChat } from '../protocol/commands'
import { chatKey } from '../protocol/receipts'
import type { RemoteCommand, RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'

/** New chats and searches sent from this tab (or still unconfirmed) that the Mac has not published yet. */
export function pendingCreations(state: EngineState, device: RemoteDevice): RemoteCommand[] {
  const listed = new Set(device.snapshot.chats.map((chat) => chat.id))
  const candidates = [
    ...state.receipts.commands,
    ...state.commands.filter((command) => state.own.has(command.id)),
  ]
  const seen = new Set<string>()
  return candidates.filter((command) => {
    if (seen.has(command.id) || !createsChat(command) || command.device.toLowerCase() !== device.id.toLowerCase()) return false
    seen.add(command.id)
    return !listed.has(command.chat) && command.status !== 'rejected' && command.status !== 'uncertain'
  })
}

/** The latest command this tab sent in a chat, for its delivery line. */
export function latestOwnCommand(state: EngineState, device: string, chat: string, kinds?: string[]): RemoteCommand | undefined {
  return state.commands.find((command) => state.own.has(command.id) && command.device.toLowerCase() === device.toLowerCase()
    && command.chat === chat && (!kinds || kinds.includes(command.kind)))
}

/** The reply to an approval or a question (answer or decline): both carry the request handle. */
export function approvalCommand(state: EngineState, device: string, chat: string, approval: string): RemoteCommand | undefined {
  return state.commands.find((command) => command.device.toLowerCase() === device.toLowerCase() && command.chat === chat
    && (command.approval ?? '').toLowerCase() === approval.toLowerCase())
}

/** Messages queued from a browser or phone that the chat's published queue does not show yet. */
export function unlistedQueueCommands(state: EngineState, device: string, chat: { id: string; queue?: { command?: string | null }[] | null }): RemoteCommand[] {
  const listed = new Set((chat.queue ?? []).flatMap((item) => (item.command ? [item.command.toLowerCase()] : [])))
  return state.commands.filter((command) => command.device.toLowerCase() === device.toLowerCase() && command.chat === chat.id
    && ['queue', 'interrupt'].includes(command.kind) && ['pending', 'claimed'].includes(command.status) && !listed.has(command.id.toLowerCase())).reverse()
}

export function keyOf(device: RemoteDevice, chat: string): string {
  return chatKey(device.id, chat)
}
