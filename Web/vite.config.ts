import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'

/** Dev server only: `/?preview=1` loads `src/preview/main.tsx` (sample data, no Supabase) instead of the app.
 *  `apply: 'serve'` keeps it out of `vite build`, so the preview code and its fixtures never reach the bundle. */
const preview: Plugin = {
  name: 'switchboard-preview',
  apply: 'serve',
  transformIndexHtml(html, context) {
    const url = new URL(context.originalUrl ?? context.path, 'http://localhost')
    return url.searchParams.get('preview') === '1' ? html.replace('/src/main.tsx', '/src/preview/main.tsx') : html
  },
}

export default defineConfig({
  plugins: [react(), preview],
  // One bundle (React, supabase-js, marked, DOMPurify) of about 170 KB gzipped.
  build: { sourcemap: false, target: 'es2022', chunkSizeWarningLimit: 800 },
})
