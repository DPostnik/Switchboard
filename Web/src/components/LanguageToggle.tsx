import { s } from '../i18n/strings'

export function LanguageToggle({ onToggle }: { onToggle: () => void }) {
  return (
    <button type="button" className="ghost small" onClick={onToggle} title={s('languageToggleHint')} aria-label={s('languageToggleHint')}>
      {s('languageToggle')}
    </button>
  )
}
