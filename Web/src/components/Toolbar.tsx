import { createContext, useContext, type ReactNode } from 'react'
import { s } from '../i18n/strings'
import { Icon } from './Icon'

export interface Shell {
  sidebarVisible: boolean
  toggleSidebar: () => void
}

export const ShellContext = createContext<Shell>({ sidebarVisible: true, toggleSidebar: () => {} })

/** The window toolbar of the Mac app: sidebar toggle, then the title with the project as subtitle. */
export function Toolbar({ title, subtitle, children }: { title: string; subtitle?: string | null; children?: ReactNode }) {
  const shell = useContext(ShellContext)
  return (
    <header className="toolbar">
      <button type="button" className="icon-button" onClick={shell.toggleSidebar} aria-label={s('toggleSidebar')} title={s('toggleSidebar')}
        aria-expanded={shell.sidebarVisible} aria-controls="sidebar">
        <Icon name="sidebar" size={18} />
      </button>
      <div className="toolbar-titles">
        <h1 className="toolbar-title ellipsis">{title}</h1>
        {subtitle && <div className="toolbar-subtitle ellipsis">{subtitle}</div>}
      </div>
      {children && <div className="toolbar-trailing">{children}</div>}
    </header>
  )
}
