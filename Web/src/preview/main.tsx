// Dev-only entry for `npm run dev` + `/?preview=1`: the workspace on sample data, with no Supabase client and no network.
// The dev server swaps it in for `src/main.tsx` (see vite.config.ts); production builds never reference this file.
import type { SupabaseClient } from '@supabase/supabase-js'
import { StrictMode, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { SignIn } from '../components/SignIn'
import { WorkspaceShell } from '../components/Workspace'
import { language, setLanguage, t, type Language } from '../i18n'
import '../styles.css'
import { PreviewEngine } from './PreviewEngine'

if (!import.meta.env.DEV) throw new Error('The preview runs only on the dev server.')

const params = new URLSearchParams(location.search)
const lang = params.get('lang')
setLanguage(lang === 'ru' || lang === 'en' ? lang : language())

/** `theme=dark` applies the dark palette regardless of the system setting, for screenshots. */
function forceDarkTheme(): void {
  const rules: string[] = []
  for (const sheet of Array.from(document.styleSheets)) {
    let list: CSSRuleList
    try {
      list = sheet.cssRules
    } catch {
      continue
    }
    for (const rule of Array.from(list)) {
      if (rule instanceof CSSMediaRule && rule.conditionText.includes('prefers-color-scheme: dark')) {
        rules.push(...Array.from(rule.cssRules).map((inner) => inner.cssText))
      }
    }
  }
  const style = document.createElement('style')
  style.textContent = rules.join('\n')
  document.head.append(style)
}
if (params.get('theme') === 'dark') requestAnimationFrame(forceDarkTheme)

/** `screen=signin`: the sign-in form with a stub client whose sign-in always fails locally. */
const stubClient = { auth: { signInWithPassword: async () => ({ error: { status: 400 } }) } } as unknown as SupabaseClient

function PreviewApp() {
  const engine = useMemo(() => new PreviewEngine(), [])
  const [current, setCurrent] = useState<Language>(language())
  const toggle = () => {
    const next = current === 'ru' ? 'en' : 'ru'
    setLanguage(next)
    setCurrent(next)
  }
  if (params.get('screen') === 'signin') return <SignIn key={current} client={stubClient} onToggleLanguage={toggle} />
  return (
    <WorkspaceShell key={current} engine={engine} lang={current} onToggleLanguage={toggle}
      onSignOut={() => window.alert(t('Предпросмотр: выход не выполняется.', 'Preview: signing out does nothing.'))} />
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <PreviewApp />
  </StrictMode>,
)
