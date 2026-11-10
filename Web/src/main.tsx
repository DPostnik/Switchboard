import { installPhotoDropGuard } from './components/photoDropGuard'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { language, setLanguage } from './i18n'
import './styles.css'

setLanguage(language())

installPhotoDropGuard()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
