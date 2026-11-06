import { locale, t } from '../i18n'
import { s } from '../i18n/strings'
import type { RemoteCommand } from '../protocol/types'

export function formatElapsed(seconds: number): string {
  if (seconds >= 3600) {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    return t(`${hours} ч ${minutes} мин`, `${hours}h ${minutes}m`)
  }
  if (seconds >= 60) return t(`${Math.floor(seconds / 60)} мин ${seconds % 60} с`, `${Math.floor(seconds / 60)}m ${seconds % 60}s`)
  return t(`${seconds} с`, `${seconds}s`)
}

export function formatDate(date: Date): string {
  return date.toLocaleDateString(locale(), { day: 'numeric', month: 'short' })
}

export function formatDateTime(date: Date): string {
  return date.toLocaleString(locale(), { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
}

/** "5 min ago", "yesterday", or a date. */
export function formatRelative(iso: string | null | undefined, now = Date.now()): string | null {
  if (!iso) return null
  const value = Date.parse(iso)
  if (!Number.isFinite(value)) return null
  const seconds = Math.max(0, Math.round((now - value) / 1000))
  if (seconds < 45) return t('только что', 'just now')
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return t(`${minutes} мин назад`, `${minutes} min ago`)
  const hours = Math.round(minutes / 60)
  if (hours < 24) return t(`${hours} ч назад`, `${hours} h ago`)
  return formatDateTime(new Date(value))
}

export function commandStatusText(command: Pick<RemoteCommand, 'status' | 'kind'>): string {
  if (command.status === 'submitted') {
    switch (command.kind) {
      case 'queue': return s('statusQueued')
      case 'interrupt': return s('statusInterrupted')
      case 'answer': return s('statusAnswered')
      case 'restore': return s('statusRestored')
      case 'create':
      case 'search': return s('statusCreated')
    }
  }
  switch (command.status) {
    case 'pending': return s('statusPending')
    case 'claimed': return s('statusClaimed')
    case 'submitted': return s('statusSubmitted')
    case 'stop_requested': return s('statusStopRequested')
    case 'rejected': return s('statusRejected')
    default: return s('statusUncertain')
  }
}

export function statusTone(status: string): 'ok' | 'wait' | 'bad' {
  if (status === 'submitted' || status === 'stop_requested') return 'ok'
  if (status === 'pending' || status === 'claimed') return 'wait'
  return 'bad'
}
