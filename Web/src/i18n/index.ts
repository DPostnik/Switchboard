/** Two UI languages. Every user-visible string goes through `t(ru, en)` or `s(key)`. */
export type Language = 'ru' | 'en'

/** Text kept in both languages, for messages created before the user may switch the language. */
export interface Bilingual {
  ru: string
  en: string
}

const storageKey = 'switchboard.language'

export function detectLanguage(stored: string | null, browser: string | undefined): Language {
  if (stored === 'ru' || stored === 'en') return stored
  return (browser ?? '').toLowerCase().startsWith('ru') ? 'ru' : 'en'
}

function initialLanguage(): Language {
  let stored: string | null = null
  try {
    stored = globalThis.localStorage?.getItem(storageKey) ?? null
  } catch {
    stored = null
  }
  return detectLanguage(stored, globalThis.navigator?.language)
}

let current: Language = initialLanguage()

export function language(): Language {
  return current
}

export function setLanguage(value: Language): void {
  current = value
  try {
    globalThis.localStorage?.setItem(storageKey, value)
  } catch {
    // Private mode: the choice lasts for this page only.
  }
  if (globalThis.document) globalThis.document.documentElement.lang = value
}

export function t(ru: string, en: string): string {
  return current === 'ru' ? ru : en
}

export function tx(text: Bilingual): string {
  return t(text.ru, text.en)
}

export function bi(ru: string, en: string): Bilingual {
  return { ru, en }
}

export function locale(): string {
  return current === 'ru' ? 'ru-RU' : 'en-US'
}
