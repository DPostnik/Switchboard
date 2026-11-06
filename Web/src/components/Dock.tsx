import { useState, type ReactNode } from 'react'
import { t, tx } from '../i18n'
import { s, type StringKey } from '../i18n/strings'
import { commands, isValidAnswers, validateAnswers } from '../protocol/commands'
import { chatKey } from '../protocol/receipts'
import type { RemoteApproval, RemoteChat, RemoteDevice, RemoteInteraction, RemoteQuestion } from '../protocol/types'
import { describeError } from '../sync/errors'
import type { EngineState } from '../sync/engine'
import type { EngineLike } from './engineLike'
import { commandStatusText, statusTone } from './format'
import { Icon } from './Icon'
import { approvalCommand, unlistedQueueCommands } from './selectors'

/** Everything under a chat's transcript, in the composer's column: delivery notice, the request waiting for an answer
 *  (approval, then question), the desktop queue, then the composer. The working row sits at the end of the transcript. */
export function Dock({ engine, state, device, chat, children }: { engine: EngineLike; state: EngineState; device: RemoteDevice; chat: RemoteChat; children: ReactNode }) {
  const key = chatKey(device.id, chat.id)
  const pending = (id: string) => approvalCommand(state, device.id, chat.id, id)
  // The first request without an accepted reply; once all have one, the first, so its status stays visible.
  const approval = chat.approvals.find((value) => (pending(value.id)?.status ?? 'rejected') === 'rejected') ?? chat.approvals[0]
  const interactions = chat.interactions ?? []
  const interaction = interactions.find((value) => (pending(value.id)?.status ?? 'rejected') === 'rejected') ?? interactions[0]
  return (
    <div className="dock">
      <DeliveryNotice engine={engine} state={state} keyValue={key} />
      {approval ? (
        <ApprovalCard engine={engine} state={state} device={device} chat={chat} approval={approval}
          position={chat.approvals.indexOf(approval) + 1} total={chat.approvals.length} />
      ) : interaction ? (
        <QuestionCard key={interaction.id} engine={engine} state={state} device={device} chat={chat} interaction={interaction}
          position={interactions.indexOf(interaction) + 1} total={interactions.length} />
      ) : null}
      <QueueList state={state} device={device} chat={chat} />
      {children}
    </div>
  )
}

/** The unresolved command of a chat (or of a new chat in a project): unknown outcome, or proven absent. */
export function DeliveryNotice({ engine, state, keyValue }: { engine: EngineLike; state: EngineState; keyValue: string }) {
  const receipt = state.receipts.blocking(keyValue)
  const busy = state.inFlight.has(keyValue)
  const error = state.chatErrors[keyValue]
  if (!receipt && !error) return null
  const missing = receipt ? state.undelivered.has(receipt.id) : false
  return (
    <div className={'banner ' + (receipt ? 'attention' : 'problem')} role="status">
      <Icon name="warning" />
      <div className="banner-body">
        {receipt && <div>{busy ? s('sending') : missing ? s('deliveryMissing') : s('deliveryUnknown')}</div>}
        {error && <div>{tx(error)}</div>}
      </div>
      <div className="banner-actions">
        {receipt && !busy && !missing && <button type="button" className="button" onClick={() => void engine.checkDelivery(receipt)}>{s('checkDelivery')}</button>}
        {receipt && !busy && missing && (
          <>
            <button type="button" className="button" onClick={() => engine.discard(receipt)}>{s('discard')}</button>
            <button type="button" className="button primary" onClick={() => void engine.resend(receipt)}>{s('sendAgain')}</button>
          </>
        )}
        {!receipt && error && (
          <button type="button" className="icon-button" onClick={() => engine.clearError(keyValue)} aria-label={s('dismiss')} title={s('dismiss')}>
            <Icon name="close" />
          </button>
        )}
      </div>
    </div>
  )
}

function Counter({ position, total }: { position: number; total: number }) {
  if (total <= 1) return null
  return <span className="card-counter">{t(`${position} из ${total}`, `${position} of ${total}`)}</span>
}

function ApprovalCard({ engine, state, device, chat, approval, position, total }: { engine: EngineLike; state: EngineState; device: RemoteDevice; chat: RemoteChat; approval: RemoteApproval; position: number; total: number }) {
  const response = approvalCommand(state, device.id, chat.id, approval.id)
  const locked = engine.isBlocked(chatKey(device.id, chat.id)) || (response !== undefined && response.status !== 'rejected')
  const base = { owner: engine.owner, device: device.id, project: chat.project }
  const reply = (kind: 'allow' | 'deny') => void engine.perform(() => (kind === 'allow'
    ? commands.allow(base, chat.id, approval.id, chat.turn)
    : commands.deny(base, chat.id, approval.id, chat.turn)))
  return (
    <div className="action-card" role="group" aria-label={s('approvalRequired')}>
      <div className="action-head">
        <Icon name="diamond" size={17} className="action-icon" />
        <strong className="action-title">{s('approvalRequired')}</strong>
        <Counter position={position} total={total} />
      </div>
      <pre className="action-details">{approval.details}</pre>
      {!approval.canAllow && <div className="action-note">{s('cannotAllowHere')}</div>}
      <div className="action-buttons">
        <button type="button" className="button" disabled={locked} onClick={() => reply('deny')}>{s('decline')}</button>
        {approval.canAllow && <button type="button" className="button primary" disabled={locked} onClick={() => reply('allow')}>{s('allowOnce')}</button>}
      </div>
      {response && <div className={'status-line ' + statusTone(response.status)} role="status">{commandStatusText(response)}</div>}
    </div>
  )
}

const macOnlyText: Record<string, StringKey> = {
  secret: 'macOnlySecret', tooLarge: 'macOnlyTooLarge', unsupported: 'macOnlyUnsupported', link: 'macOnlyLink', setup: 'macOnlySetup',
}

/** A question or tool form: options, free text where the agent accepts it ("Other"), Decline where the desktop has it.
 *  A request that cannot be shown faithfully says "answer on the Mac". */
function QuestionCard({ engine, state, device, chat, interaction, position, total }: { engine: EngineLike; state: EngineState; device: RemoteDevice; chat: RemoteChat; interaction: RemoteInteraction; position: number; total: number }) {
  const [chosen, setChosen] = useState<Record<string, string>>({})
  const [other, setOther] = useState<Record<string, string>>({})
  const [typing, setTyping] = useState<Set<string>>(new Set())
  const [localError, setLocalError] = useState<string | null>(null)
  const response = approvalCommand(state, device.id, chat.id, interaction.id)
  const locked = engine.isBlocked(chatKey(device.id, chat.id)) || (response !== undefined && response.status !== 'rejected')
  const isQuestions = interaction.kind === 'questions'

  const answers: Record<string, string> = {}
  for (const question of interaction.questions) {
    const value = typing.has(question.id) || question.options.length === 0 ? other[question.id] ?? '' : chosen[question.id] ?? ''
    // Questions need every key; a form leaves out what the user did not fill in.
    if (isQuestions || value.trim() !== '') answers[question.id] = value
  }
  const valid = interaction.canAnswer && isValidAnswers(interaction, answers)
  const base = { owner: engine.owner, device: device.id, project: chat.project }

  const send = () => {
    try {
      validateAnswers(interaction, answers)
    } catch (error) {
      setLocalError(tx(describeError(error)))
      return
    }
    setLocalError(null)
    void engine.perform(() => commands.answer(base, chat.id, interaction.id, answers))
  }
  const decline = () => void engine.perform(() => commands.deny(base, chat.id, interaction.id, chat.turn))
  const macOnly = interaction.canAnswer ? null : s(macOnlyText[interaction.macOnly ?? ''] ?? 'answerOnMac')

  const optionRow = (question: RemoteQuestion) => {
    const selected = typing.has(question.id) ? null : chosen[question.id] ?? null
    const preview = question.options.find((option) => option.label === selected)?.preview
    return (
      <fieldset className="options" disabled={locked}>
        <legend className="sr-only">{question.text}</legend>
        {question.options.map((option, index) => (
          <label key={index} className={'option' + (selected === option.label ? ' selected' : '')}>
            <input type="radio" name={interaction.id + ':' + question.id} checked={selected === option.label}
              onChange={() => {
                setChosen((value) => ({ ...value, [question.id]: option.label }))
                setTyping((value) => { const next = new Set(value); next.delete(question.id); return next })
              }} />
            <span className="option-text">
              <span className="option-label">{option.label}</span>
              {option.description && <span className="option-description">{option.description}</span>}
            </span>
          </label>
        ))}
        {question.allowsOther && (
          <label className={'option other' + (typing.has(question.id) || question.options.length === 0 ? ' selected' : '')}>
            {question.options.length > 0 && (
              <input type="radio" name={interaction.id + ':' + question.id} checked={typing.has(question.id)}
                onChange={() => setTyping((value) => new Set(value).add(question.id))} />
            )}
            <textarea rows={1} className="field-input" placeholder={question.options.length ? s('otherAnswer') : s('answer')} value={other[question.id] ?? ''}
              aria-label={question.options.length ? s('otherAnswer') : s('answer')}
              onFocus={() => question.options.length && setTyping((value) => new Set(value).add(question.id))}
              onChange={(event) => setOther((value) => ({ ...value, [question.id]: event.target.value }))} />
          </label>
        )}
        {preview && <pre className="action-details">{preview}</pre>}
      </fieldset>
    )
  }

  return (
    <div className="action-card" role="group" aria-label={isQuestions ? s('question') : s('toolRequest')}>
      <div className="action-head">
        <Icon name="diamond" size={17} className="action-icon" />
        <strong className="action-title">{isQuestions ? s('question') : s('toolRequest')}</strong>
        <Counter position={position} total={total} />
      </div>
      <div className="action-scroll">
        {interaction.message && <p className="action-message">{interaction.message}</p>}
        {interaction.questions.map((question) => (
          <div key={question.id} className="question-block">
            {question.header && <div className="question-header">{question.header}</div>}
            <div className="question-text">
              {question.text}
              {!question.required && interaction.canAnswer && <span className="question-optional"> · {s('optional')}</span>}
            </div>
            {interaction.canAnswer ? optionRow(question) : question.options.length > 0 && (
              <div className="action-note">{question.options.map((option) => option.label).join(' · ')}</div>
            )}
          </div>
        ))}
      </div>
      {macOnly && <div className="action-note">{macOnly}</div>}
      {(interaction.canAnswer || interaction.canDecline) && (
        <div className="action-buttons">
          {interaction.canDecline && <button type="button" className="button" disabled={locked} onClick={decline}>{s('decline')}</button>}
          {interaction.canAnswer && <button type="button" className="button primary" disabled={locked || !valid} onClick={send}>{s('sendAnswer')}</button>}
        </div>
      )}
      {localError && <div className="status-line bad" role="alert">{localError}</div>}
      {response && <div className={'status-line ' + statusTone(response.status)} role="status">{commandStatusText(response)}</div>}
    </div>
  )
}

/** The chat's desktop queue, with messages from the browser or phone still on their way. */
function QueueList({ state, device, chat }: { state: EngineState; device: RemoteDevice; chat: RemoteChat }) {
  const queued = chat.queue ?? []
  const sending = unlistedQueueCommands(state, device.id, chat)
  const total = Math.max(chat.queueCount ?? 0, queued.length) + sending.length
  if (total === 0) return null
  const shown = 3
  const rows = [
    ...queued.slice(0, Math.max(1, shown - sending.length)).map((item) => ({
      id: item.id, text: item.text, note: item.claimed ? s('queuedSending') : null, remote: Boolean(item.command),
    })),
    ...sending.map((command) => ({ id: 'command:' + command.id, text: command.text, note: commandStatusText(command), remote: true })),
  ]
  const title = chat.queuePaused ? s('queuePaused') : t(`В очереди · ${total}`, `Queued · ${total}`)
  return (
    <section className="queue" aria-label={title}>
      <div className="queue-head">{title}</div>
      <ul className="queue-list">
        {rows.map((row) => (
          <li key={row.id} className="queue-row">
            <span className="queue-origin" title={row.remote ? s('fromBrowser') : s('fromMac')}>
              <Icon name={row.remote ? 'phone' : 'desktop'} size={14} label={row.remote ? s('fromBrowser') : s('fromMac')} />
            </span>
            <span className="queue-text" title={row.text}>{row.text}</span>
            {row.note && <span className="queue-note">{row.note}</span>}
          </li>
        ))}
      </ul>
      {total > rows.length && <div className="queue-more">{t(`Ещё ${total - rows.length}`, `+${total - rows.length} more`)}</div>}
    </section>
  )
}
