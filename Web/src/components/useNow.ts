import { useEffect, useState } from 'react'

/** Current time, refreshed every `interval` milliseconds while `active`. */
export function useNow(interval: number, active = true): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), interval)
    return () => clearInterval(timer)
  }, [interval, active])
  return now
}
