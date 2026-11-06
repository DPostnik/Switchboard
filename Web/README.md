# Switchboard web client

Browser access to the agent chats of your Mac: a static single-page app (Vite, React, TypeScript,
`@supabase/supabase-js`) that talks to the same Supabase project as the iPhone app. The Mac stays the
only executor: the site reads the published state and inserts commands into `remote_commands`.
The protocol is described in `docs/web-client-plan.md`; the Swift sources in `Sources/ContextCore/MobileRemote.swift`
and `MobileRealtime.swift` are the source of truth.

## Setup

```sh
cd Web
npm ci
# Local configuration (never commit it): the project URL and the publishable key,
# the same values as `url` and `key` in ~/Library/Application Support/Switchboard/mobile-remote.json.
printf 'VITE_SUPABASE_URL=%s\nVITE_SUPABASE_KEY=%s\n' "<url>" "<publishable key>" > .env.local
npm run dev        # http://localhost:5173
npm test           # vitest: protocol layer and i18n
npm run build      # tsc + vite build into dist/
```

Sign in with the Supabase Auth owner account (email and password); public sign-up stays off.

## Environment variables

| Name | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `VITE_SUPABASE_KEY` | Publishable key (`sb_publishable_…`) or the legacy anon key. Never a service role or secret key: the app refuses to start with one. |

Both are baked into the static build, so they must be set in the Vercel project for every environment.

## Deploy (Vercel)

- Vercel project `switchboard-web` (team "daniil's projects"), connected to `DPostnik/Switchboard`; every push to
  `main` deploys. Project root directory: `Web` (framework preset Vite, build `npm run build`, output `dist`).
- `vercel.json` rewrites every path to `index.html` (single-page app) and adds basic security headers.
- Domain: `switchboard.daniilpostnik.com` (DNS on Vercel).
- Password sign-in needs no redirect URLs in Supabase Auth.

Sign out ends only this browser's session (`scope: 'local'`). The default global scope would also end the
Mac's and the iPhone's sessions, because all clients share the owner account.

## Layout

- `src/protocol/` – wire types, command construction and validation (mirror of `RemoteCommand.validate()`),
  snapshot delta merge, web transcripts, `switchboard-chat:` links, REST calls, receipts. No React.
- `src/sync/engine.ts` – Realtime channel (`remote:<owner>`, Presence role `phone`), synchronization and command delivery.
- `src/components/` – the React UI. `src/i18n/` – Russian and English strings.
