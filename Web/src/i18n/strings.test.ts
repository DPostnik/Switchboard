import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { detectLanguage, setLanguage, t } from './index'
import { s, strings } from './strings'

const cyrillic = /[А-Яа-яЁё]/
/** Strings that are the same in both languages (names). */
const sameInBoth = new Set(['appName', 'mac'])

describe('i18n', () => {
  it('has a non-empty Russian and English text for every key', () => {
    for (const [key, [ru, en]] of Object.entries(strings)) {
      expect(ru.trim(), key).not.toBe('')
      expect(en.trim(), key).not.toBe('')
      // The language toggle names the other language, so it is written in that language.
      if (sameInBoth.has(key) || key.startsWith('languageToggle')) continue
      expect(cyrillic.test(ru), `${key} ru`).toBe(true)
      expect(cyrillic.test(en), `${key} en`).toBe(false)
    }
  })

  it('switches language', () => {
    setLanguage('ru')
    expect(s('signIn')).toBe('Войти')
    expect(t('да', 'yes')).toBe('да')
    setLanguage('en')
    expect(s('signIn')).toBe('Sign in')
  })

  it('detects the language from storage, then the browser', () => {
    expect(detectLanguage('en', 'ru-RU')).toBe('en')
    expect(detectLanguage(null, 'ru-RU')).toBe('ru')
    expect(detectLanguage(null, 'de-DE')).toBe('en')
    expect(detectLanguage('xx', undefined)).toBe('en')
  })

  it('gives every t(ru, en) call in the sources two string arguments', () => {
    const files: string[] = []
    const walk = (directory: string) => {
      for (const name of readdirSync(directory)) {
        const path = join(directory, name)
        if (statSync(path).isDirectory()) walk(path)
        else if (/\.tsx?$/.test(name) && !name.endsWith('.test.ts')) files.push(path)
      }
    }
    walk(join(import.meta.dirname, '..'))
    const call = /\b(?:t|bi)\(\s*(['`])((?:\\.|(?!\1).)*)\1\s*,\s*(['`])((?:\\.|(?!\3).)*)\3\s*\)/g
    let calls = 0
    for (const file of files) {
      const source = readFileSync(file, 'utf8')
      for (const match of source.matchAll(call)) {
        calls += 1
        expect(match[2].trim(), file).not.toBe('')
        expect(match[4].trim(), file).not.toBe('')
        expect(cyrillic.test(match[2]), `${file}: ${match[2]}`).toBe(true)
      }
    }
    expect(calls).toBeGreaterThan(10)
  })
})
