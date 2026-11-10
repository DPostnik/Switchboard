// Wire types of the Switchboard remote protocol (snapshot version 1).
// Source of truth: Sources/ContextCore/MobileRemote.swift and MobileRealtime.swift.
// Unknown fields are ignored; every field added after the first version is optional.

export interface RemoteModelOption {
  id: string
  name: string
  /** Engine that runs the model; absent means Codex. */
  agent?: string | null
}

export type RemoteAccessMode = 'standard' | 'fullAccess'

export interface RemoteChatOptions {
  model: string
  access?: RemoteAccessMode | null
  role?: string | null
  addOns?: string[] | null
}

export interface RemoteRoleOption {
  id: string
  name: string
}

export interface RemoteAddOnOption {
  id: string
  name: string
  summary?: string | null
  symbol?: string | null
}

export interface RemoteChatSettings {
  options: RemoteChatOptions
  projectAccess: RemoteAccessMode
  canEdit: boolean
  projectRole?: string | null
  roles?: RemoteRoleOption[] | null
  addOns?: RemoteAddOnOption[] | null
  projectAddOns?: string[] | null
}

export interface RemoteProject {
  id: string
  name: string
  canCreateChat?: boolean | null
  models?: RemoteModelOption[] | null
  newChatModels?: RemoteModelOption[] | null
  settings?: RemoteChatSettings | null
  canReadFiles?: boolean | null
  /** Web additions. */
  canSearchChats?: boolean | null
  canUseWeb?: boolean | null
}

export interface RemoteMessage {
  id: string
  role: string
  text: string
  truncated?: boolean | null
}

export interface RemoteApproval {
  id: string
  details: string
  canAllow: boolean
}

export interface RemoteQuestionOption {
  label: string
  description?: string | null
  preview?: string | null
}

export interface RemoteQuestion {
  id: string
  header?: string | null
  text: string
  options: RemoteQuestionOption[]
  multiSelect?: boolean | null
  allowsOther: boolean
  secret?: boolean | null
  required: boolean
}

export type InteractionKind = 'questions' | 'form' | 'link' | 'unsupported'
export type MacOnlyReason = 'secret' | 'tooLarge' | 'unsupported' | 'link' | 'setup'

export interface RemoteInteraction {
  id: string
  kind: string
  message?: string | null
  questions: RemoteQuestion[]
  canAnswer: boolean
  canDecline: boolean
  macOnly?: string | null
}

export interface RemoteQueuedMessage {
  id: string
  text: string
  truncated?: boolean | null
  command?: string | null
  claimed?: boolean | null
}

export interface RemoteChat {
  id: string
  project: string
  title: string
  running: boolean
  turn?: string | null
  messages: RemoteMessage[]
  approvals: RemoteApproval[]
  supportsPhotos?: boolean | null
  settings?: RemoteChatSettings | null
  readOnly?: boolean | null
  activity?: string | null
  runningSince?: string | null
  interactions?: RemoteInteraction[] | null
  queue?: RemoteQueuedMessage[] | null
  queueCount?: number | null
  queuePaused?: boolean | null
  canQueue?: boolean | null
  canInterrupt?: boolean | null
  /** Web additions. */
  web?: boolean | null
  webMessages?: number | null
  chatSearch?: boolean | null
}

export interface RemoteSnapshot {
  version: number
  projects: RemoteProject[]
  chats: RemoteChat[]
}

export interface RemoteDevice {
  id: string
  owner: string
  name: string
  seen: string
  snapshot: RemoteSnapshot
  projects: string[]
  revision?: number | null
}

/** Result of `read_remote_changes(device_id, since_revision)`: the device with an empty chat list,
 *  the chats changed after `since_revision`, and the full chat order. */
export interface RemoteSnapshotDelta {
  device: RemoteDevice
  chats: RemoteChat[]
  order: string[]
}

export type CommandKind =
  | 'send' | 'stop' | 'allow' | 'deny' | 'create' | 'configure' | 'file'
  | 'answer' | 'queue' | 'interrupt' | 'restore' | 'search'

export type CommandStatus = 'pending' | 'claimed' | 'submitted' | 'stop_requested' | 'rejected' | 'uncertain'

export interface RemoteSettingsChange {
  options: RemoteChatOptions
  expected?: RemoteChatOptions | null
  expectedProjectAccess?: RemoteAccessMode | null
}

export interface RemotePhoto { id: string; data: string }

export interface RemoteCommand {
  photos?: RemotePhoto[] | null
  id: string
  owner: string
  device: string
  project: string
  chat: string
  kind: CommandKind | string
  text: string
  approval?: string | null
  turn?: string | null
  status: CommandStatus | string
  settings?: RemoteSettingsChange | null
  answers?: Record<string, string> | null
}

/** A full message of a web chat (`remote_web_messages`). */
export interface WebMessage {
  id: string
  seq: number
  role: string
  text: string
  truncated?: boolean | null
}

/** Realtime invalidation (`changed` broadcast on `remote:<owner>`). */
export interface RemoteInvalidation {
  entity: string
  device: string
  id?: string
  status?: string
  chat?: string
}
