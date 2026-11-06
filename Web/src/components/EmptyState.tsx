import type { ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

/** Centered icon, title and text, as the Mac app's empty states. */
export function EmptyState({ icon, title, text, busy = false, children }: { icon: IconName; title: string; text?: string; busy?: boolean; children?: ReactNode }) {
  return (
    <div className="empty-state" role={busy ? 'status' : undefined}>
      {busy ? <span className="pulse-dot large" aria-hidden="true" /> : <Icon name={icon} size={32} className="empty-icon" />}
      <h2 className="empty-title">{title}</h2>
      {text && <p className="empty-text">{text}</p>}
      {children && <div className="empty-actions">{children}</div>}
    </div>
  )
}
