/** Small per-browser preferences; private mode keeps them for the page only. */
export function stored(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}

export function store(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    // Not persisted in private mode.
  }
}
