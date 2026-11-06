import { bi, type Bilingual } from '../i18n'
import { RemoteError } from '../protocol/api'
import { InvalidAnswerError, InvalidCommandError } from '../protocol/commands'

/** User-facing description of a failure, in both languages. */
export function describeError(error: unknown): Bilingual {
  if (error instanceof InvalidAnswerError) return bi('Ответь на все обязательные вопросы. Ничего не отправлено.', 'Answer every required question. Nothing was sent.')
  if (error instanceof InvalidCommandError) return bi('Команда недоступна или устарела. Ничего не отправлено.', 'Command unavailable or stale. Nothing was sent.')
  if (error instanceof RemoteError) {
    switch (error.kind) {
      case 'signedOut': return bi('Войди заново.', 'Sign in again.')
      case 'notStored': return error.status
        ? bi(`Сервер отклонил команду (${error.status}). Ничего не отправлено.`, `The server refused the command (${error.status}). Nothing was sent.`)
        : bi('Команда не отправлена: нет сессии или сети. Ничего не отправлено.', 'The command was not sent: no session or network. Nothing was sent.')
      case 'uncertain': return bi('Результат неизвестен. Проверь доставку; автоматического повтора нет.', 'Outcome unknown. Check delivery; there is no automatic retry.')
      case 'setup': return bi('Обнови схему мобильного доступа в Supabase.', 'Update the Supabase mobile access schema.')
      case 'invalid': return bi('Неверный идентификатор.', 'Invalid identifier.')
      case 'request': return error.status
        ? bi(`Ошибка Supabase (${error.status}).`, `Supabase error (${error.status}).`)
        : bi('Нет связи с Supabase.', 'Cannot reach Supabase.')
    }
  }
  const message = error instanceof Error ? error.message : String(error)
  return bi(`Ошибка: ${message}`, `Error: ${message}`)
}
