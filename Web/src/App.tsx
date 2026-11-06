import type { Session } from '@supabase/supabase-js'
import { useEffect, useState } from 'react'
import { LanguageToggle } from './components/LanguageToggle'
import { SignIn } from './components/SignIn'
import { Workspace } from './components/Workspace'
import { language, setLanguage, type Language } from './i18n'
import { s } from './i18n/strings'
import { configProblem, supabase } from './supabase'

export default function App() {
  const [lang, setLang] = useState<Language>(language())
  const [session, setSession] = useState<Session | null>(null)
  const [ready, setReady] = useState(false)

  const switchLanguage = () => {
    const next = lang === 'ru' ? 'en' : 'ru'
    setLanguage(next)
    setLang(next)
  }

  useEffect(() => {
    if (!supabase) return
    let alive = true
    void supabase.auth.getSession().then(({ data }) => {
      if (!alive) return
      setSession(data.session)
      setReady(true)
    })
    const { data } = supabase.auth.onAuthStateChange((_event, value) => {
      // Only the user identity matters here; token refreshes keep the same workspace.
      setSession((previous) => (previous?.user.id === value?.user.id ? previous ?? value : value))
      setReady(true)
    })
    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [])

  if (!supabase || configProblem) {
    const message = configProblem === 'url' ? s('configURL') : configProblem === 'secretKey' ? s('configSecretKey') : s('configMissing')
    return (
      <div className="center-screen" key={lang}>
        <div className="card narrow">
          <div className="card-top"><h1>{s('appName')}</h1><LanguageToggle onToggle={switchLanguage} /></div>
          <p className="error">{message}</p>
        </div>
      </div>
    )
  }
  if (!ready) return <div className="center-screen" key={lang} role="status"><span className="pulse-dot large" aria-hidden="true" /><span className="sr-only">{s('loading')}</span></div>
  if (!session) return <SignIn key={lang} client={supabase} onToggleLanguage={switchLanguage} />
  return <Workspace key={session.user.id} lang={lang} client={supabase} owner={session.user.id} onToggleLanguage={switchLanguage} />
}
