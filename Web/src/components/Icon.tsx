/** Line icons drawn after the SF Symbols the Mac app uses, so the site needs no icon font. Decorative by default. */
export type IconName =
  | 'sidebar' | 'compose' | 'search' | 'folder' | 'folderFill' | 'chevronRight' | 'arrowUp' | 'stop' | 'globe'
  | 'signOut' | 'copy' | 'check' | 'sparkle' | 'lock' | 'lockOpen' | 'desktop' | 'bubbles' | 'warning' | 'diamond'
  | 'hourglass' | 'close' | 'arrowDown' | 'tray' | 'cpu' | 'person' | 'phone' | 'interrupt'

const paths: Record<IconName, string> = {
  sidebar: 'M2.5 3.5h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1ZM6 3.5v9M3.3 5.6h1.3M3.3 7.4h1.3',
  compose: 'M13.6 2.4a1.4 1.4 0 0 1 0 2L8 10l-2.3.6.6-2.3 5.6-5.6a1.4 1.4 0 0 1 1.7-.3ZM12 8.6V12.5a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3.9',
  search: 'M7 12A5 5 0 1 0 7 2a5 5 0 0 0 0 10ZM10.6 10.6 14 14',
  folder: 'M1.8 4.2a1 1 0 0 1 1-1h3.4l1.5 1.5h5.5a1 1 0 0 1 1 1v6.6a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1V4.2Z',
  folderFill: 'M1.8 4.2a1 1 0 0 1 1-1h3.4l1.5 1.5h5.5a1 1 0 0 1 1 1v6.6a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1V4.2Z',
  chevronRight: 'M6 3.5 10.5 8 6 12.5',
  arrowUp: 'M8 13V3.4M3.8 7.4 8 3.2l4.2 4.2',
  stop: 'M4.5 4.5h7v7h-7z',
  globe: 'M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4ZM1.9 8h12.2M8 1.8c1.7 1.7 2.5 3.8 2.5 6.2S9.7 12.5 8 14.2C6.3 12.5 5.5 10.4 5.5 8S6.3 3.5 8 1.8Z',
  signOut: 'M9.5 3V2.5a1 1 0 0 0-1-1h-5a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h5a1 1 0 0 0 1-1V13M6.5 8h8M12 5.5 14.5 8 12 10.5',
  copy: 'M5.5 5.5V3a1 1 0 0 1 1-1H13a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-2.5M3 5.5h6.5a1 1 0 0 1 1 1V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V6.5a1 1 0 0 1 1-1Z',
  check: 'M3 8.5 6.4 12 13 4.5',
  sparkle: 'M8 1.5c.5 3.4 1.6 4.8 5.5 6.5-3.9 1.7-5 3.1-5.5 6.5-.5-3.4-1.6-4.8-5.5-6.5 3.9-1.7 5-3.1 5.5-6.5Z',
  lock: 'M4 7.2h8a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1ZM5.3 7.2V5.1a2.7 2.7 0 0 1 5.4 0v2.1',
  lockOpen: 'M4 7.2h8a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1ZM5.3 7.2V5.1a2.7 2.7 0 0 1 5.2-1',
  desktop: 'M2.5 2.5h11a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V3.5a1 1 0 0 1 1-1ZM6 14h4M8 11v3',
  bubbles: 'M2 3.2a1 1 0 0 1 1-1h6.5a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1H5.2L3 10V8.2H3a1 1 0 0 1-1-1v-4ZM12.2 5.5h.8a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1v1.8l-2.2-1.8H7.5a1 1 0 0 1-1-1V10',
  warning: 'M7.1 2.4a1 1 0 0 1 1.8 0l5.5 10a1 1 0 0 1-.9 1.5H2.5a1 1 0 0 1-.9-1.5l5.5-10ZM8 6v3.3M8 11.4v.2',
  diamond: 'M7.3 1.7a1 1 0 0 1 1.4 0l5.6 5.6a1 1 0 0 1 0 1.4l-5.6 5.6a1 1 0 0 1-1.4 0L1.7 8.7a1 1 0 0 1 0-1.4l5.6-5.6ZM8 4.8v3.8M8 10.8v.2',
  hourglass: 'M4 1.8h8M4 14.2h8M5 1.8v2.4L8 8l3-3.8V1.8M5 14.2v-2.4L8 8l3 3.8v2.4',
  close: 'M4 4l8 8M12 4l-8 8',
  arrowDown: 'M8 3v9.6M3.8 8.6 8 12.8l4.2-4.2',
  tray: 'M1.8 9.2 3.6 3.4a1 1 0 0 1 1-.7h6.8a1 1 0 0 1 1 .7l1.8 5.8v3.3a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1V9.2Zm0 0h3.6l.8 1.6h3.6l.8-1.6h3.6',
  cpu: 'M4.5 4.5h7v7h-7zM6.5 2v2.5M9.5 2v2.5M6.5 11.5V14M9.5 11.5V14M2 6.5h2.5M2 9.5h2.5M11.5 6.5H14M11.5 9.5H14',
  person: 'M8 7.5a2.7 2.7 0 1 0 0-5.4 2.7 2.7 0 0 0 0 5.4ZM2.8 14c.4-2.7 2.5-4.4 5.2-4.4s4.8 1.7 5.2 4.4',
  phone: 'M5 1.5h6a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1ZM7 12.5h2',
  interrupt: 'M3 3v10M7 8h6.5M10.5 5l3 3-3 3',
}

const filled = new Set<IconName>(['folderFill', 'stop', 'sparkle'])

export function Icon({ name, size = 16, label, className }: { name: IconName; size?: number; label?: string; className?: string }) {
  const fill = filled.has(name)
  return (
    <svg className={'icon' + (className ? ' ' + className : '')} width={size} height={size} viewBox="0 0 16 16"
      fill={fill ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth={fill ? 1.2 : 1.5} strokeLinecap="round" strokeLinejoin="round"
      role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true} focusable="false">
      <path d={paths[name]} />
    </svg>
  )
}
