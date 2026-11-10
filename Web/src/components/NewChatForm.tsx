import { useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode } from 'react'
import { t } from '../i18n'
import { s } from '../i18n/strings'
import { commands, limits, utf8Length } from '../protocol/commands'
import { creationKey } from '../protocol/receipts'
import { agentTitle, newChatModels, newChatRoles } from '../protocol/snapshot'
import type { RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import { usePhotoAttachments } from './usePhotoAttachments'
import { useAutosize } from './Composer'
import { DeliveryNotice } from './Dock'
import { EmptyState } from './EmptyState'
import type { EngineLike } from './engineLike'
import { Icon, type IconName } from './Icon'
import { submitOnEnter } from './keys'
import { Toolbar } from './Toolbar'

interface Props {
  engine: EngineLike
  state: EngineState
  device: RemoteDevice
  initialProject: string
  onOpen: (chat: string) => void
  onCancel: () => void
}

/** A new chat as the Mac app starts one: an empty transcript with a greeting, and the composer with its chips. */
export function NewChatForm({ engine, state, device, initialProject, onOpen, onCancel }: Props) {
  const projects = device.snapshot.projects.filter((project) => project.canUseWeb === true && project.canCreateChat !== false)
  const [projectID, setProjectID] = useState(() => (projects.some((project) => project.id === initialProject) ? initialProject : projects[0]?.id ?? ''))
  const project = projects.find((value) => value.id === projectID)
  const models = newChatModels(project)
  const { roles, defaultRole } = newChatRoles(project)
  const [modelChoice, setModel] = useState('')
  const [roleChoice, setRole] = useState('')
  const [text, setText] = useState('')
  const field = useRef<HTMLTextAreaElement>(null)
  useAutosize(field, text)
  const model = models.some((value) => value.id === modelChoice) ? modelChoice
    : models.find((value) => value.id === project?.settings?.options.model)?.id ?? models[0]?.id ?? ''
  const role = roles.some((value) => value.id === roleChoice) ? roleChoice : defaultRole ?? ''
  const key = project ? creationKey(device.id, project.id) : ''
  const blocked = key ? engine.isBlocked(key) : true
  const { photos, setPhotos, loadingPhotos, photoError, draggingPhotos, picker, addPhotos, onPaste, clearSent } =
    usePhotoAttachments(key, Boolean(project && model), () => !key || engine.isBlocked(key))
  const hasContent = text.trim() !== '' || photos.length > 0
  const tooLong = utf8Length(text) > limits.textBytes

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!project || !model || !hasContent || blocked || loadingPhotos || tooLong) return
    const sentPhotos = photos
    const command = await engine.perform((owner) => {
      const value = commands.create({ owner, device: device.id, project: project.id }, text, { model, role: role || null })
      if (sentPhotos.length) value.photos = sentPhotos
      return value
    })
    if (command) {
      clearSent(sentPhotos)
      setText('')
      onOpen(command.chat)
    }
  }

  if (projects.length === 0) {
    return (
      <FormPage title={s('newChatTitle')} onCancel={onCancel}>
        <EmptyState icon="folder" title={s('newChatTitle')} text={s('noProjects')} />
      </FormPage>
    )
  }
  const sending = state.inFlight.has(key)
  return (
    <FormPage title={s('newChatTitle')} subtitle={project?.name} onCancel={onCancel}>
      <EmptyState icon="bubbles" title={s('newChatHeadline')}
        text={project ? t(`Первое сообщение создаст новый чат в папке «${project.name}»`, `Your first message will create a new chat in “${project.name}”`) : undefined} />
      <form className={'dock' + (draggingPhotos ? ' dragging-photos' : '')} onSubmit={submit} onKeyDown={cancelOnEscape(onCancel)}>
        {draggingPhotos && <div className="photo-drop-hint" role="status">{s('dropPhotos')}</div>}
        {photoError && <div role="alert" className="composer-note bad">{s(photoError)}</div>}
        {photos.length > 0 && <div className="photo-strip">{photos.map(photo => <button type="button" key={photo.id} disabled={blocked || loadingPhotos} aria-label={s('removePhoto')} onClick={() => setPhotos(photos.filter(p => p.id !== photo.id))}><img src={'data:image/jpeg;base64,' + photo.data} alt={s('attachedPhoto')} /></button>)}</div>}
        {models.length === 0 && <div className="composer-note bad">{s('noModels')}</div>}
        {tooLong && <div className="composer-note bad" role="alert">{s('textTooLong')}</div>}
        {key && <DeliveryNotice engine={engine} state={state} keyValue={key} />}
        {blocked && key && state.receipts.blocking(key) && <div className="composer-note">{s('creationPending')}</div>}
        <div className="composer">
          <textarea ref={field} className="composer-input" rows={1} value={text} placeholder={s('firstMessagePlaceholder')} aria-label={s('firstMessage')}
            onPaste={onPaste} onChange={(event) => setText(event.target.value)} onKeyDown={submitOnEnter} autoFocus />
          <div className="composer-bar">
            <input ref={picker} type="file" accept="image/*" multiple hidden onChange={event => { void addPhotos(Array.from(event.target.files ?? [])); event.target.value = '' }} />
            <button type="button" className="chip-button" disabled={blocked || loadingPhotos || photos.length >= 4 || !model} onClick={() => picker.current?.click()}>{s(loadingPhotos ? 'preparingPhotos' : 'attachPhotos')}</button>
            <ChipSelect icon="folder" label={s('project')} value={projectID} onChange={(value) => { setProjectID(value); setModel(''); setRole('') }}>
              {projects.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
            </ChipSelect>
            {roles.length > 0 && (
              <ChipSelect icon="lock" label={s('role')} value={role} onChange={setRole}>
                {roles.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
              </ChipSelect>
            )}
            <ChipSelect icon="sparkle" label={s('model')} value={model} onChange={setModel} disabled={models.length === 0}>
              {models.map((value) => <option key={value.id} value={value.id}>{value.name} · {agentTitle(value)}</option>)}
            </ChipSelect>
            <span className="composer-spacer" />
            <button type="submit" className="round-button" disabled={!model || !hasContent || blocked || loadingPhotos || tooLong}
              aria-label={s('startChat')} title={s('startChat')} aria-busy={sending || undefined}>
              <Icon name="arrowUp" size={15} />
            </button>
          </div>
        </div>
      </form>
    </FormPage>
  )
}

/** Escape leaves the page, as closing a sheet on the Mac. */
export function cancelOnEscape(onCancel: () => void) {
  return (event: KeyboardEvent) => {
    if (event.key !== 'Escape' || event.defaultPrevented) return
    event.preventDefault()
    onCancel()
  }
}

/** A page with the toolbar, a centered greeting and the composer at the bottom. */
export function FormPage({ title, subtitle, onCancel, children }: { title: string; subtitle?: string; onCancel: () => void; children: ReactNode }) {
  return (
    <section className="chat">
      <Toolbar title={title} subtitle={subtitle}>
        <button type="button" className="button text" onClick={onCancel}>{s('cancel')}</button>
      </Toolbar>
      {children}
    </section>
  )
}

/** A native select drawn as a composer chip: icon, current value, chevron. */
export function ChipSelect({ icon, label, value, onChange, disabled = false, children }: { icon: IconName; label: string; value: string; onChange: (value: string) => void; disabled?: boolean; children: ReactNode }) {
  return (
    <label className={'chip chip-select' + (disabled ? ' disabled' : '')} title={label}>
      <Icon name={icon} size={13} />
      <select value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled} aria-label={label}>{children}</select>
      <svg className="chip-chevron" width="8" height="8" viewBox="0 0 8 8" aria-hidden="true"><path d="M1.5 3 4 5.5 6.5 3" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>
    </label>
  )
}
