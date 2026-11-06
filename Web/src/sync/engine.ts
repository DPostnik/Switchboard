// Connection, synchronization and command delivery of one signed-in tab, mirroring MobileModel.swift.
// Order on every (re)connect: subscribe first, then read, so no change between the two is lost.
import type { RealtimeChannel, SupabaseClient } from '@supabase/supabase-js'
import type { Bilingual } from '../i18n'
import { RemoteAPI, RemoteError } from '../protocol/api'
import { newCommandID, validateCommand } from '../protocol/commands'
import { Receipts, chatKey, receiptKey } from '../protocol/receipts'
import { channelName, parseInvalidation, presenceRole, presentMacs } from '../protocol/realtime'
import { changedChats, mergeFetched, replaceDevice } from '../protocol/snapshot'
import type { RemoteCommand, RemoteDevice, WebMessage } from '../protocol/types'
import { describeError } from './errors'

export type Connection = 'connecting' | 'syncing' | 'connected' | 'retrying' | 'offline' | 'signedOut' | 'failed' | 'stopped'

export interface WebTranscript {
  messages: WebMessage[] | null
  loading: boolean
  stale: boolean
  error: Bilingual | null
}

export interface EngineState {
  connection: Connection
  error: Bilingual | null
  /** The first full read finished. */
  synced: boolean
  devices: RemoteDevice[]
  /** Recent commands of every Mac, newest first. */
  commands: RemoteCommand[]
  /** IDs of commands sent from this tab. */
  own: ReadonlySet<string>
  macs: ReadonlySet<string>
  receipts: Receipts
  /** Receipts the cloud lookup did not find after their send had ended. */
  undelivered: ReadonlySet<string>
  /** Chat or creation keys with a submission in flight. */
  inFlight: ReadonlySet<string>
  chatErrors: Readonly<Record<string, Bilingual>>
  /** Full transcripts of web chats by chat key. */
  web: Readonly<Record<string, WebTranscript>>
  /** Last activity of web chats: device -> chat -> ISO date. */
  lastActive: Readonly<Record<string, Readonly<Record<string, string>>>>
  /** False when the cloud has no web tables yet. */
  webTables: boolean | null
}

/** Runs one operation at a time; requests made meanwhile merge into one more run. */
class SerialWork {
  private running = false
  private dirty = false
  private timer: ReturnType<typeof setTimeout> | null = null
  private ticket = 0
  request(delay: number, operation: () => Promise<void>, failure: (error: unknown) => void): void {
    this.dirty = true
    if (this.running || this.timer) return
    const ticket = this.ticket
    this.timer = setTimeout(async () => {
      this.timer = null
      if (ticket !== this.ticket) return
      this.running = true
      try {
        while (this.dirty && ticket === this.ticket) {
          this.dirty = false
          await operation()
        }
      } catch (error) {
        if (ticket === this.ticket) failure(error)
      } finally {
        if (ticket === this.ticket) this.running = false
      }
    }, delay)
  }
  cancel(): void {
    this.ticket += 1
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.running = false
    this.dirty = false
  }
}

class Cancelled extends Error {}

const replicationWait = 5000
const presenceIdle = 120_000
const webDebounce = 300
const lastActiveDebounce = 2000

export class Engine {
  readonly api: RemoteAPI
  readonly owner: string
  private readonly client: SupabaseClient
  private readonly tab = newCommandID()
  private readonly receiptStorage: string
  private state: EngineState
  private listeners = new Set<() => void>()
  private channel: RealtimeChannel | null = null
  private generation = 0
  private work = new SerialWork()
  private dirtyDevices = new Set<string>()
  private dirtyCommands = new Set<string>()
  private needsFullSync = false
  private retryAttempt = 0
  private retryTimer: ReturnType<typeof setTimeout> | null = null
  private replicationReady = false
  private webTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private webLoading = new Set<string>()
  private webAgain = new Set<string>()
  private activeTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private watched: { device: string; chat: string } | null = null
  private tracked = false
  private hiddenTimer: ReturnType<typeof setTimeout> | null = null
  private stopped = true
  private cleanup: (() => void)[] = []

  constructor(client: SupabaseClient, owner: string) {
    this.client = client
    this.owner = owner
    this.api = new RemoteAPI(client)
    this.receiptStorage = 'switchboard.receipts.' + owner.toLowerCase()
    let stored: string | null = null
    try {
      stored = localStorage.getItem(this.receiptStorage)
    } catch {
      stored = null
    }
    this.state = {
      connection: 'stopped', error: null, synced: false, devices: [], commands: [], own: new Set(), macs: new Set(),
      receipts: Receipts.parse(stored), undelivered: new Set(), inFlight: new Set(), chatErrors: {}, web: {}, lastActive: {}, webTables: null,
    }
  }

  // MARK: Store

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }
  getState = (): EngineState => this.state

  private set(patch: Partial<EngineState>): void {
    this.state = { ...this.state, ...patch }
    for (const listener of this.listeners) listener()
  }

  // MARK: Connection

  start(): void {
    if (!this.stopped) return
    this.stopped = false
    const online = () => {
      if (this.state.connection === 'offline') this.set({ connection: 'retrying' })
      this.requestFullSync()
    }
    const offline = () => this.set({ connection: 'offline' })
    const visibility = () => this.visibilityChanged()
    window.addEventListener('online', online)
    window.addEventListener('offline', offline)
    document.addEventListener('visibilitychange', visibility)
    this.cleanup = [
      () => window.removeEventListener('online', online),
      () => window.removeEventListener('offline', offline),
      () => document.removeEventListener('visibilitychange', visibility),
    ]
    void this.connect()
  }

  stop(): void {
    this.stopped = true
    this.generation += 1
    this.work.cancel()
    this.cleanup.forEach((dispose) => dispose())
    this.cleanup = []
    for (const timer of [...this.webTimers.values(), ...this.activeTimers.values()]) clearTimeout(timer)
    this.webTimers.clear()
    this.activeTimers.clear()
    if (this.retryTimer) clearTimeout(this.retryTimer)
    if (this.hiddenTimer) clearTimeout(this.hiddenTimer)
    const channel = this.channel
    this.channel = null
    if (channel) void this.client.removeChannel(channel)
    this.set({ connection: 'stopped', macs: new Set() })
  }

  private async connect(): Promise<void> {
    const ticket = ++this.generation
    this.replicationReady = false
    this.set({ connection: navigator.onLine === false ? 'offline' : 'connecting' })
    try {
      // Private channels authorize with the session token.
      await this.client.realtime.setAuth()
    } catch {
      // supabase-js sets the token again on the next auth event.
    }
    if (ticket !== this.generation || this.stopped) return
    const channel = this.client.channel(channelName(this.owner), {
      config: {
        private: true,
        // replication_ready: the server reports when database broadcasts flow, before the first read.
        broadcast: { ack: false, self: false, replication_ready: true } as { ack: boolean; self: boolean },
        presence: { key: presenceRole + ':' + this.tab, enabled: true },
      },
    })
    this.channel = channel
    channel.on('broadcast', { event: 'changed' }, (message: { payload?: unknown }) => this.invalidated(message.payload))
    channel.on('presence', { event: 'sync' }, () => {
      const macs = presentMacs(channel.presenceState() as Record<string, unknown[]>)
      const previous = this.state.macs
      if (macs.size !== previous.size || [...macs].some((id) => !previous.has(id))) this.set({ macs })
    })
    channel.on('system', {}, (payload: Record<string, unknown>) => {
      if (payload?.extension === 'system' && payload?.status === 'ok') this.replicationReady = true
    })
    channel.subscribe((status, error) => {
      if (ticket !== this.generation || this.stopped) return
      if (status === 'SUBSCRIBED') void this.subscribed(ticket)
      else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        this.work.cancel()
        this.tracked = false
        const message = (error as Error | undefined)?.message ?? ''
        const unauthorized = /unauthori[sz]ed|permission|denied|jwt/i.test(message)
        this.set({ connection: navigator.onLine === false ? 'offline' : unauthorized ? 'failed' : 'retrying', macs: new Set() })
      } else if (status === 'CLOSED') {
        this.tracked = false
        this.set({ connection: 'retrying', macs: new Set() })
        this.scheduleReconnect()
      }
    })
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.retryTimer) return
    const delay = Math.min(30, 2 ** Math.min(this.retryAttempt, 5)) * 1000 * (0.8 + Math.random() * 0.4)
    this.retryAttempt = Math.min(this.retryAttempt + 1, 6)
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      if (this.stopped) return
      // Callbacks of the old channel (its CLOSED included) belong to an older generation.
      this.generation += 1
      const channel = this.channel
      this.channel = null
      if (channel) void this.client.removeChannel(channel)
      void this.connect()
    }, delay)
  }

  private async subscribed(ticket: number): Promise<void> {
    this.work.cancel()
    this.dirtyDevices.clear()
    this.dirtyCommands.clear()
    if (document.visibilityState !== 'hidden') await this.track(true)
    const began = Date.now()
    while (!this.replicationReady && Date.now() - began < replicationWait) {
      await new Promise((resolve) => setTimeout(resolve, 100))
      if (ticket !== this.generation) return
    }
    this.set({ connection: 'syncing' })
    this.needsFullSync = true
    this.requestUpdates(0)
  }

  private async track(on: boolean): Promise<void> {
    const channel = this.channel
    if (!channel || on === this.tracked) return
    this.tracked = on
    try {
      if (on) await channel.track({ role: presenceRole, device: this.tab })
      else await channel.untrack()
    } catch {
      this.tracked = !on
    }
  }

  /** A hidden tab stops counting as a watching phone after a while, so the Mac can slow down. */
  private visibilityChanged(): void {
    if (this.hiddenTimer) clearTimeout(this.hiddenTimer)
    this.hiddenTimer = null
    if (document.visibilityState === 'hidden') {
      this.hiddenTimer = setTimeout(() => void this.track(false), presenceIdle)
    } else {
      void this.track(true)
      this.requestFullSync()
    }
  }

  private invalidated(payload: unknown): void {
    const event = parseInvalidation(payload)
    if (!event) return // Unknown events are ignored; events never carry instructions.
    if (event.entity === 'device') this.dirtyDevices.add(event.device)
    else if (event.entity === 'command' && event.id) this.dirtyCommands.add(event.id)
    else if (event.entity === 'web' && event.chat) {
      this.webChanged(event.device, event.chat)
      return
    }
    this.requestUpdates()
  }

  requestFullSync(): void {
    if (this.stopped) return
    this.needsFullSync = true
    this.requestUpdates(0)
  }

  private requestUpdates(delay = 40): void {
    if (this.stopped) return
    if (!this.needsFullSync && this.dirtyDevices.size === 0 && this.dirtyCommands.size === 0) return
    this.work.request(delay, () => this.applyChanges(), (error) => this.syncFailed(error))
  }

  private syncFailed(error: unknown): void {
    if (error instanceof Cancelled || this.stopped) return
    if (error instanceof RemoteError && error.kind === 'signedOut') {
      this.set({ connection: 'signedOut', error: describeError(error) })
      return
    }
    if (error instanceof RemoteError && error.kind === 'setup') {
      this.set({ connection: 'failed', error: describeError(error) })
      return
    }
    this.set({ connection: navigator.onLine === false ? 'offline' : 'retrying', error: describeError(error) })
    // Reads are safe to repeat; commands are never resent here.
    this.needsFullSync = true
    const delay = Math.min(30, 2 ** Math.min(this.retryAttempt, 5)) * 1000
    this.retryAttempt = Math.min(this.retryAttempt + 1, 6)
    setTimeout(() => this.requestUpdates(0), delay)
  }

  private async synchronize(): Promise<void> {
    const ticket = this.generation
    if (this.state.connection !== 'connected') await this.api.checkRealtimeSchema()
    const fetched = await this.api.devices()
    const updated: RemoteCommand[] = []
    for (const device of fetched) updated.push(...(await this.api.commands(device.id)))
    // An unconfirmed command may be older than the bounded recent list.
    for (const receipt of this.state.receipts.commands) {
      if (updated.some((command) => command.id === receipt.id)) continue
      const found = await this.api.command(receipt.id)
      if (found) updated.push(found)
    }
    const lastActive: Record<string, Record<string, string>> = {}
    let webTables = this.state.webTables
    for (const device of fetched) {
      try {
        const value = await this.api.webChats(device.id)
        if (value === null) webTables = false
        else {
          lastActive[device.id] = value
          webTables = true
        }
      } catch {
        // Older cloud schema: no expiry dates.
      }
    }
    if (ticket !== this.generation || this.stopped) throw new Cancelled()
    const devices = mergeFetched(this.state.devices, fetched)
    const known = new Set(updated.map((command) => command.id))
    const kept = this.state.commands.filter((command) => this.state.own.has(command.id) && !known.has(command.id) && devices.some((device) => device.id === command.device))
    // A reconnect may have missed web broadcasts: every transcript is read again when opened.
    const web: Record<string, WebTranscript> = {}
    for (const [key, value] of Object.entries(this.state.web)) web[key] = { ...value, stale: true }
    this.set({ devices, commands: [...updated, ...kept], lastActive, webTables, web, synced: true, error: null, connection: 'connected' })
    this.retryAttempt = 0
    this.resolveDelivery()
    if (this.watched) this.loadWeb(this.watched.device, this.watched.chat)
  }

  private async applyChanges(): Promise<void> {
    const ticket = this.generation
    if (this.needsFullSync) {
      this.needsFullSync = false
      await this.synchronize()
    }
    const deviceIDs = [...this.dirtyDevices]
    this.dirtyDevices.clear()
    const commandIDs = [...this.dirtyCommands]
    this.dirtyCommands.clear()
    for (const id of deviceIDs) {
      const previous = this.state.devices.find((device) => device.id === id)
      const delta = await this.api.changes(id, previous?.revision ?? -1)
      if (ticket !== this.generation || this.stopped) throw new Cancelled()
      const devices = replaceDevice(this.state.devices, id, delta)
      const next = devices.find((device) => device.id === id)
      this.set({
        devices,
        commands: delta ? this.state.commands : this.state.commands.filter((command) => command.device !== id),
      })
      for (const chat of changedChats(previous, next)) this.snapshotChatChanged(id, chat)
    }
    for (const id of commandIDs) {
      const value = await this.api.command(id)
      if (ticket !== this.generation || this.stopped) throw new Cancelled()
      const commands = this.state.commands.filter((command) => command.id !== id)
      if (value) {
        const index = this.state.commands.findIndex((command) => command.id === id)
        if (index >= 0) commands.splice(index, 0, value)
        else commands.unshift(value)
      }
      this.set({ commands })
    }
    this.resolveDelivery()
    if (this.state.commands.length > 600) this.set({ commands: this.state.commands.slice(0, 600) })
    if (this.state.connection !== 'connected') this.set({ connection: 'connected', error: null })
  }

  // MARK: Web transcripts

  /** The chat open on screen; its full transcript is kept current. */
  watch(device: string | null, chat: string | null): void {
    this.watched = device && chat ? { device: device.toLowerCase(), chat } : null
    if (this.watched) {
      const entry = this.state.web[chatKey(this.watched.device, this.watched.chat)]
      if (!entry || entry.stale) this.loadWeb(this.watched.device, this.watched.chat)
    }
  }

  private isWatched(device: string, chat: string): boolean {
    return this.watched?.device === device.toLowerCase() && this.watched.chat === chat
  }

  private markStale(key: string): void {
    const entry = this.state.web[key]
    if (entry && !entry.stale) this.set({ web: { ...this.state.web, [key]: { ...entry, stale: true } } })
  }

  private webChanged(device: string, chat: string): void {
    const key = chatKey(device, chat)
    this.markStale(key)
    if (this.isWatched(device, chat)) this.scheduleWeb(device, chat)
    // Last activity moves with every write of the chat.
    const existing = this.activeTimers.get(device)
    if (existing) clearTimeout(existing)
    this.activeTimers.set(device, setTimeout(() => {
      this.activeTimers.delete(device)
      void this.refreshLastActive(device)
    }, lastActiveDebounce))
  }

  private snapshotChatChanged(device: string, chat: string): void {
    const key = chatKey(device, chat)
    if (!this.state.web[key] && !this.isWatched(device, chat)) return
    this.markStale(key)
    if (this.isWatched(device, chat)) this.scheduleWeb(device, chat)
  }

  private scheduleWeb(device: string, chat: string): void {
    const key = chatKey(device, chat)
    const existing = this.webTimers.get(key)
    if (existing) clearTimeout(existing)
    this.webTimers.set(key, setTimeout(() => {
      this.webTimers.delete(key)
      this.loadWeb(device, chat)
    }, webDebounce))
  }

  private async refreshLastActive(device: string): Promise<void> {
    try {
      const value = await this.api.webChats(device)
      if (value && !this.stopped) this.set({ lastActive: { ...this.state.lastActive, [device]: value } })
    } catch {
      // Shown again after the next full read.
    }
  }

  private loadWeb(device: string, chat: string): void {
    const key = chatKey(device, chat)
    if (this.stopped || this.state.webTables === false) return
    const chatValue = this.state.devices.find((value) => value.id === device)?.snapshot.chats.find((value) => value.id === chat)
    if (chatValue && chatValue.web !== true) return
    if (this.webLoading.has(key)) {
      this.webAgain.add(key)
      return
    }
    this.webLoading.add(key)
    const ticket = this.generation
    const previous = this.state.web[key]
    this.set({ web: { ...this.state.web, [key]: { messages: previous?.messages ?? null, loading: true, stale: false, error: null } } })
    void this.api.webMessages(device, chat).then(
      (messages) => {
        if (ticket !== this.generation || this.stopped) return
        const current = this.state.web[key]
        this.set({ web: { ...this.state.web, [key]: { messages, loading: false, stale: current?.stale ?? false, error: null } } })
      },
      (error: unknown) => {
        if (ticket !== this.generation || this.stopped) return
        const current = this.state.web[key]
        const missing = error instanceof RemoteError && error.status === 404
        this.set({
          webTables: missing ? false : this.state.webTables,
          web: { ...this.state.web, [key]: { messages: current?.messages ?? null, loading: false, stale: true, error: missing ? null : describeError(error) } },
        })
      },
    ).finally(() => {
      this.webLoading.delete(key)
      if (this.webAgain.delete(key)) this.loadWeb(device, chat)
    })
  }

  // MARK: Delivery receipts

  private saveReceipts(receipts: Receipts): void {
    const value = receipts.serialize()
    if (value) localStorage.setItem(this.receiptStorage, value)
    else localStorage.removeItem(this.receiptStorage)
    this.set({ receipts })
  }

  /** A receipt is resolved once the queue reports its command, whatever its status. */
  private resolveDelivery(): void {
    const { receipts, removed } = this.state.receipts.resolve(this.state.commands.map((command) => command.id))
    if (!removed.length) return
    try {
      this.saveReceipts(receipts)
    } catch {
      this.set({ receipts })
    }
    const undelivered = new Set(this.state.undelivered)
    removed.forEach((id) => undelivered.delete(id))
    this.set({ undelivered })
  }

  isBlocked(key: string): boolean {
    return this.state.inFlight.has(key) || this.state.receipts.blocking(key) !== undefined
  }

  private setInFlight(key: string, on: boolean): void {
    const inFlight = new Set(this.state.inFlight)
    if (on) inFlight.add(key)
    else inFlight.delete(key)
    this.set({ inFlight })
  }

  private setChatError(key: string, error: Bilingual | null): void {
    const chatErrors = { ...this.state.chatErrors }
    if (error) chatErrors[key] = error
    else delete chatErrors[key]
    this.set({ chatErrors })
  }

  clearError(key: string): void {
    this.setChatError(key, null)
  }

  /** Builds, validates and submits one command; `key` is its chat or creation key (see `receiptKey`). */
  async perform(make: (owner: string) => RemoteCommand): Promise<RemoteCommand | null> {
    let key: string | null = null
    try {
      const command = make(this.owner)
      if (this.isBlocked(receiptKey(command))) return null
      key = receiptKey(command)
      this.setInFlight(key, true)
      validateCommand(command)
      await this.submit(command)
      this.setChatError(key, null)
      return command
    } catch (error) {
      if (key) this.setChatError(key, describeError(error))
      return null
    } finally {
      if (key) this.setInFlight(key, false)
    }
  }

  private async submit(command: RemoteCommand): Promise<void> {
    // Save the stable ID before networking. Never resubmit after a transport failure.
    this.saveReceipts(this.state.receipts.record(command))
    const undelivered = new Set(this.state.undelivered)
    undelivered.delete(command.id)
    this.set({ undelivered, own: new Set([...this.state.own, command.id]) })
    try {
      await this.api.submit(command)
    } catch (error) {
      // The server proved it stored nothing, so the receipt must not block later sends.
      if (error instanceof RemoteError && error.kind === 'notStored') this.saveReceipts(this.state.receipts.remove(command.id))
      throw error
    }
    this.saveReceipts(this.state.receipts.remove(command.id))
    if (!this.state.commands.some((value) => value.id === command.id)) this.set({ commands: [command, ...this.state.commands] })
    this.dirtyCommands.add(command.id)
    this.requestUpdates()
  }

  /** Looks one unresolved command up by ID. Absence after its send ended means the queue never stored it. */
  async checkDelivery(receipt: RemoteCommand): Promise<void> {
    const key = receiptKey(receipt)
    if (this.state.inFlight.has(key)) return
    this.setInFlight(key, true)
    try {
      const found = await this.api.command(receipt.id)
      if (found) {
        if (!this.state.commands.some((command) => command.id === found.id)) this.set({ commands: [found, ...this.state.commands] })
        this.resolveDelivery()
      } else this.set({ undelivered: new Set([...this.state.undelivered, receipt.id]) })
      this.setChatError(key, null)
    } catch (error) {
      this.setChatError(key, describeError(error))
    } finally {
      this.setInFlight(key, false)
    }
  }

  /** Sends the same command again. Its ID is the primary key, so the Mac can never receive it twice. */
  async resend(receipt: RemoteCommand): Promise<void> {
    const key = receiptKey(receipt)
    if (!this.state.undelivered.has(receipt.id) || this.state.inFlight.has(key)) return
    this.setInFlight(key, true)
    try {
      await this.submit(receipt)
      this.setChatError(key, null)
    } catch (error) {
      this.setChatError(key, describeError(error))
    } finally {
      this.setInFlight(key, false)
    }
  }

  /** Only a receipt the cloud proved absent can be discarded; an unknown one keeps its chat blocked. */
  discard(receipt: RemoteCommand): void {
    const key = receiptKey(receipt)
    if (!this.state.undelivered.has(receipt.id) || this.state.inFlight.has(key)) return
    try {
      this.saveReceipts(this.state.receipts.remove(receipt.id))
      const undelivered = new Set(this.state.undelivered)
      undelivered.delete(receipt.id)
      this.set({ undelivered })
      this.setChatError(key, null)
    } catch (error) {
      this.setChatError(key, describeError(error))
    }
  }
}
