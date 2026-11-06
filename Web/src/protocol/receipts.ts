// Delivery receipts, mirroring MobileReceipts.swift: commands whose queue insert is not confirmed.
// A receipt is saved before networking and removed once the cloud queue is known to hold the command
// (or proved it does not). It is never resent automatically, and it blocks later commands of its chat only.
import { createsChat } from './commands'
import type { RemoteCommand } from './types'

export function chatKey(device: string, chat: string): string {
  return device.toLowerCase() + '|' + chat
}

/** New chats and searches are keyed by project: a second creation could duplicate an unconfirmed one. */
export function creationKey(device: string, project: string): string {
  return device.toLowerCase() + '|create:' + project.toLowerCase()
}

export function receiptKey(command: RemoteCommand): string {
  return createsChat(command) ? creationKey(command.device, command.project) : chatKey(command.device, command.chat)
}

export class Receipts {
  readonly commands: readonly RemoteCommand[]
  constructor(commands: readonly RemoteCommand[] = []) {
    const seen = new Set<string>()
    this.commands = commands.filter((command) => {
      const id = command.id.toLowerCase()
      return seen.has(id) ? false : (seen.add(id), true)
    })
  }
  static parse(text: string | null): Receipts {
    if (!text) return new Receipts()
    try {
      const value = JSON.parse(text) as unknown
      return new Receipts(Array.isArray(value) ? (value as RemoteCommand[]).filter((item) => typeof item?.id === 'string') : [])
    } catch {
      return new Receipts()
    }
  }
  serialize(): string | null {
    return this.commands.length ? JSON.stringify(this.commands) : null
  }
  contains(id: string): boolean {
    return this.commands.some((command) => command.id.toLowerCase() === id.toLowerCase())
  }
  record(command: RemoteCommand): Receipts {
    return this.contains(command.id) ? this : new Receipts([...this.commands, command])
  }
  remove(id: string): Receipts {
    return new Receipts(this.commands.filter((command) => command.id.toLowerCase() !== id.toLowerCase()))
  }
  /** Drops receipts whose commands the queue reported; returns the new list and the removed IDs. */
  resolve(known: Iterable<string>): { receipts: Receipts; removed: string[] } {
    const ids = new Set([...known].map((id) => id.toLowerCase()))
    const removed = this.commands.filter((command) => ids.has(command.id.toLowerCase())).map((command) => command.id)
    return { receipts: removed.length ? new Receipts(this.commands.filter((command) => !ids.has(command.id.toLowerCase()))) : this, removed }
  }
  /** The unresolved command blocking this key (`chatKey` or `creationKey`). */
  blocking(key: string): RemoteCommand | undefined {
    return this.commands.find((command) => receiptKey(command) === key)
  }
}
