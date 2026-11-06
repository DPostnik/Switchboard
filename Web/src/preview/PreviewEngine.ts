// Dev-only stand-in for the sync engine: commands change the sample data in memory and never leave the page.
import type { EngineLike } from '../components/engineLike'
import { validateCommand } from '../protocol/commands'
import { receiptKey } from '../protocol/receipts'
import type { RemoteChat, RemoteCommand, RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import { previewOwner, previewState } from './fixtures'

export class PreviewEngine implements EngineLike {
  readonly owner = previewOwner
  private state: EngineState = previewState()
  private listeners = new Set<() => void>()

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }
  getState = (): EngineState => this.state

  private set(patch: Partial<EngineState>): void {
    this.state = { ...this.state, ...patch }
    for (const listener of this.listeners) listener()
  }

  private updateChat(id: string, change: (chat: RemoteChat) => RemoteChat | null): void {
    const devices = this.state.devices.map((device): RemoteDevice => ({
      ...device,
      snapshot: { ...device.snapshot, chats: device.snapshot.chats.flatMap((chat) => (chat.id === id ? [change(chat)].filter((value): value is RemoteChat => value !== null) : [chat])) },
    }))
    this.set({ devices })
  }

  private addChat(chat: RemoteChat): void {
    this.set({ devices: this.state.devices.map((device) => ({ ...device, snapshot: { ...device.snapshot, chats: [chat, ...device.snapshot.chats] } })) })
  }

  private setStatus(id: string, status: string): void {
    this.set({ commands: this.state.commands.map((command) => (command.id === id ? { ...command, status } : command)) })
  }

  watch(): void {}

  isBlocked(key: string): boolean {
    return this.state.inFlight.has(key) || this.state.receipts.blocking(key) !== undefined
  }

  async perform(make: (owner: string) => RemoteCommand): Promise<RemoteCommand | null> {
    const command = make(this.owner)
    const key = receiptKey(command)
    if (this.isBlocked(key)) return null
    try {
      validateCommand(command)
    } catch {
      this.set({ chatErrors: { ...this.state.chatErrors, [key]: { ru: 'Команда не прошла проверку.', en: 'The command failed validation.' } } })
      return null
    }
    this.set({ inFlight: new Set([...this.state.inFlight, key]) })
    await new Promise((resolve) => setTimeout(resolve, 350))
    const inFlight = new Set(this.state.inFlight)
    inFlight.delete(key)
    this.set({ inFlight, commands: [command, ...this.state.commands], own: new Set([...this.state.own, command.id]) })
    setTimeout(() => this.setStatus(command.id, 'claimed'), 700)
    setTimeout(() => this.apply(command), 1400)
    return command
  }

  /** What the Mac would do with the command, simulated on the sample data. */
  private apply(command: RemoteCommand): void {
    const now = new Date().toISOString()
    const message = (role: string, text: string) => ({ id: 'preview-' + Math.random().toString(36).slice(2), role, text })
    switch (command.kind) {
      case 'send':
        this.updateChat(command.chat, (chat) => ({ ...chat, running: true, runningSince: now, activity: 'Thinking', messages: [...chat.messages, message('user', command.text)] }))
        setTimeout(() => this.updateChat(command.chat, (chat) => ({ ...chat, running: false, activity: null, messages: [...chat.messages, message('assistant', 'Sample answer from the preview. **Nothing was sent** to a Mac.')] })), 2500)
        break
      case 'queue':
        this.updateChat(command.chat, (chat) => ({ ...chat, queue: [...(chat.queue ?? []), { id: 'q-' + command.id, text: command.text, command: command.id }], queueCount: (chat.queueCount ?? chat.queue?.length ?? 0) + 1 }))
        break
      case 'interrupt':
        this.updateChat(command.chat, (chat) => ({ ...chat, runningSince: now, messages: [...chat.messages, message('user', command.text)] }))
        break
      case 'stop':
        this.updateChat(command.chat, (chat) => ({ ...chat, running: false, activity: null }))
        break
      case 'allow':
      case 'deny':
      case 'answer':
        this.updateChat(command.chat, (chat) => ({
          ...chat,
          approvals: chat.approvals.filter((value) => value.id !== command.approval),
          interactions: (chat.interactions ?? []).filter((value) => value.id !== command.approval),
        }))
        break
      case 'create':
      case 'search':
        this.addChat({
          id: command.chat, project: command.project, title: command.text.split('\n')[0].slice(0, 60), running: true, runningSince: now, turn: 'turn-' + command.id,
          messages: [message('user', command.text)], approvals: [], web: true, chatSearch: command.kind === 'search', canQueue: true,
        })
        break
      case 'restore':
        this.addChat({
          id: command.chat, project: command.project, title: 'Restored chat', running: false,
          messages: [message('assistant', 'This chat was restored from the archive in the preview.')], approvals: [], web: true,
        })
        break
    }
    this.setStatus(command.id, 'submitted')
  }

  async checkDelivery(): Promise<void> {}
  async resend(): Promise<void> {}
  discard(): void {}
  clearError(key: string): void {
    const chatErrors = { ...this.state.chatErrors }
    delete chatErrors[key]
    this.set({ chatErrors })
  }
}
