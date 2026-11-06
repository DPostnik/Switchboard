import { createClient, type SupabaseClient } from '@supabase/supabase-js'

export type ConfigProblem = 'missing' | 'url' | 'secretKey'

/** Checks the build configuration: an HTTPS project URL and a publishable (or legacy anon) key. */
export function checkConfig(url: string | undefined, key: string | undefined): ConfigProblem | null {
  if (!url || !key) return 'missing'
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return 'url'
  }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || (parsed.pathname !== '/' && parsed.pathname !== '')) return 'url'
  if (key.startsWith('sb_secret_')) return 'secretKey'
  if (key.startsWith('ey')) {
    // A legacy JWT key must be the anon role, never service_role.
    try {
      const payload = JSON.parse(atob(key.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))) as { role?: string }
      if (payload.role !== 'anon') return 'secretKey'
    } catch {
      return 'secretKey'
    }
  } else if (!key.startsWith('sb_publishable_')) return 'secretKey'
  return null
}

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_KEY as string | undefined

export const configProblem = checkConfig(url, key)

export const supabase: SupabaseClient | null = configProblem
  ? null
  : createClient(url!, key!, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'switchboard.auth' },
    realtime: { params: { eventsPerSecond: 10 } },
  })
