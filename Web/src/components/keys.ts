import type { KeyboardEvent } from 'react'

/** Enter submits the field's form, Shift+Enter adds a line, as in the composer. */
export function submitOnEnter(event: KeyboardEvent<HTMLTextAreaElement>): void {
  if (event.key !== 'Enter' || event.shiftKey || event.altKey || event.nativeEvent.isComposing) return
  event.preventDefault()
  event.currentTarget.form?.requestSubmit()
}
