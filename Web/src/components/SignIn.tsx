import type { SupabaseClient } from '@supabase/supabase-js'
import { useState, type FormEvent } from 'react'
import { s } from '../i18n/strings'
import { LanguageToggle } from './LanguageToggle'

export function SignIn({ client, onToggleLanguage }: { client: SupabaseClient; onToggleLanguage: () => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<'credentials' | 'network' | null>(null)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      const { error: failure } = await client.auth.signInWithPassword({ email: email.trim(), password })
      if (failure) setError(failure.status && failure.status < 500 ? 'credentials' : 'network')
    } catch {
      setError('network')
    } finally {
      // The password never outlives the attempt.
      setPassword('')
      setBusy(false)
    }
  }

  return (
    <div className="center-screen">
      <form className="card narrow sign-in" onSubmit={submit}>
        <div className="card-top">
          <h1>{s('signInTitle')}</h1>
          <LanguageToggle onToggle={onToggleLanguage} />
        </div>
        <p className="muted">{s('signInLead')}</p>
        <label className="field">
          <span>{s('email')}</span>
          <input id="email" name="email" type="email" autoComplete="username" required value={email} onChange={(event) => setEmail(event.target.value)} disabled={busy} />
        </label>
        <label className="field">
          <span>{s('password')}</span>
          <input id="password" name="password" type="password" autoComplete="current-password" required value={password} onChange={(event) => setPassword(event.target.value)} disabled={busy} />
        </label>
        {error && <p className="error" role="alert">{error === 'credentials' ? s('signInFailed') : s('signInNetwork')}</p>}
        <button type="submit" className="primary" disabled={busy || !email || !password}>{busy ? s('signingIn') : s('signIn')}</button>
        <p className="muted small">{s('macExecutes')}</p>
      </form>
    </div>
  )
}
