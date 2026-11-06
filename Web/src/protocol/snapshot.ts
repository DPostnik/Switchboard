// Snapshot synchronization, mirroring RemoteSnapshotDelta.applying(to:) and MobileModel.synchronize().
import type { RemoteChat, RemoteDevice, RemoteModelOption, RemoteProject, RemoteSnapshotDelta } from './types'

const revision = (device: RemoteDevice | undefined | null): number => device?.revision ?? 0

/** Applies one delta to the device's previous state. An older revision never replaces a newer one.
 *  Chats come from the previous state overlaid with the delta's changed chats, in the delta's order. */
export function applyDelta(delta: RemoteSnapshotDelta, previous: RemoteDevice | undefined): RemoteDevice {
  if (previous && (delta.device.revision ?? 0) < (previous.revision ?? -1)) return previous
  const available = new Map<string, RemoteChat>()
  for (const chat of previous?.snapshot.chats ?? []) available.set(chat.id, chat)
  for (const chat of delta.chats ?? []) available.set(chat.id, chat)
  const chats = (delta.order ?? []).flatMap((id) => {
    const chat = available.get(id)
    return chat ? [chat] : []
  })
  return { ...delta.device, snapshot: { ...delta.device.snapshot, chats } }
}

/** Replaces devices with a full fetch, keeping a newer revision already applied from a delta.
 *  Devices missing from the fetch are removed. Only snapshot version 1 is understood. */
export function mergeFetched(current: RemoteDevice[], fetched: RemoteDevice[]): RemoteDevice[] {
  return fetched
    .filter((device) => device.snapshot?.version === 1)
    .map((device) => {
      const previous = current.find((value) => value.id === device.id)
      return previous && revision(previous) > revision(device) ? previous : device
    })
}

/** Replaces or removes one device after a delta read (`null` delta means the device is gone). */
export function replaceDevice(devices: RemoteDevice[], id: string, delta: RemoteSnapshotDelta | null): RemoteDevice[] {
  if (!delta) return devices.filter((device) => device.id !== id)
  const previous = devices.find((device) => device.id === id)
  const value = applyDelta(delta, previous)
  return previous ? devices.map((device) => (device.id === id ? value : device)) : [...devices, value]
}

/** IDs of chats whose published payload differs between two snapshots of one device. */
export function changedChats(before: RemoteDevice | undefined, after: RemoteDevice | undefined): Set<string> {
  const result = new Set<string>()
  if (!after) return result
  const previous = new Map((before?.snapshot.chats ?? []).map((chat) => [chat.id, chat]))
  for (const chat of after.snapshot.chats) {
    const old = previous.get(chat.id)
    if (!old || JSON.stringify(old) !== JSON.stringify(chat)) result.add(chat.id)
  }
  return result
}

/** Only web chats are listed, in the published order. */
export function webChats(device: RemoteDevice | undefined, project?: string | null): RemoteChat[] {
  return (device?.snapshot.chats ?? []).filter((chat) => chat.web === true && (!project || chat.project.toLowerCase() === project.toLowerCase()))
}

export function findProject(device: RemoteDevice | undefined, id: string | null | undefined): RemoteProject | undefined {
  if (!id) return undefined
  return device?.snapshot.projects.find((project) => project.id.toLowerCase() === id.toLowerCase())
}

/** Models a new chat can start with; older hosts publish only `models`. */
export function newChatModels(project: RemoteProject | undefined): RemoteModelOption[] {
  const models = project?.newChatModels ?? project?.models ?? []
  return models.filter((model) => typeof model.id === 'string' && model.id.length > 0)
}

export function agentTitle(model: RemoteModelOption): string {
  return model.agent === 'claude' ? 'Claude' : 'Codex'
}

/** Roles a new chat may use (never above the project's default) and the default one. */
export function newChatRoles(project: RemoteProject | undefined): { roles: { id: string; name: string }[]; defaultRole: string | null } {
  const roles = project?.settings?.roles ?? []
  const preferred = project?.settings?.projectRole ?? null
  const defaultRole = preferred && roles.some((role) => role.id === preferred) ? preferred : roles[0]?.id ?? preferred
  return { roles, defaultRole: defaultRole ?? null }
}

/** Elapsed seconds of the running turn, or null when idle or unknown. */
export function elapsedSeconds(chat: Pick<RemoteChat, 'running' | 'runningSince'>, now: number): number | null {
  if (!chat.running || !chat.runningSince) return null
  const start = Date.parse(chat.runningSince)
  if (!Number.isFinite(start)) return null
  const value = (now - start) / 1000
  if (!Number.isFinite(value) || value >= 1e9) return null
  return Math.max(0, Math.floor(value))
}

/** A web chat leaves the cloud this long after its last activity. */
export const webRetentionDays = 15

export function expiryDate(lastActive: string | null | undefined): Date | null {
  if (!lastActive) return null
  const value = Date.parse(lastActive)
  return Number.isFinite(value) ? new Date(value + webRetentionDays * 86_400_000) : null
}
