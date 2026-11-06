import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // One bundle (React, supabase-js, marked, DOMPurify) of about 170 KB gzipped.
  build: { sourcemap: false, target: 'es2022', chunkSizeWarningLimit: 800 },
})
