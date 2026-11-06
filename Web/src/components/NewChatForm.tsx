import { useState, type FormEvent } from 'react'
import { s } from '../i18n/strings'
import { commands, limits, utf8Length } from '../protocol/commands'
import { creationKey } from '../protocol/receipts'
import { agentTitle, newChatModels, newChatRoles } from '../protocol/snapshot'
import type { RemoteDevice } from '../protocol/types'
import type { Engine, EngineState } from '../sync/engine'
import { DeliveryNotice } from './Dock'
import { submitOnEnter } from './keys'

interface Props {
  engine: Engine
  state: EngineState
  device: RemoteDevice
  initialProject: string
  onOpen: (chat: string) => void
  onCancel: () => void
}

export function NewChatForm({ engine, state, device, initialProject, onOpen, onCancel }: Props) {
  const projects = device.snapshot.projects.filter((project) => project.canUseWeb === true && project.canCreateChat !== false)
  const [projectID, setProjectID] = useState(() => (projects.some((project) => project.id === initialProject) ? initialProject : projects[0]?.id ?? ''))
  const project = projects.find((value) => value.id === projectID)
  const models = newChatModels(project)
  const { roles, defaultRole } = newChatRoles(project)
  const [modelChoice, setModel] = useState('')
  const [roleChoice, setRole] = useState('')
  const [text, setText] = useState('')
  const model = models.some((value) => value.id === modelChoice) ? modelChoice
    : models.find((value) => value.id === project?.settings?.options.model)?.id ?? models[0]?.id ?? ''
  const role = roles.some((value) => value.id === roleChoice) ? roleChoice : defaultRole ?? ''
  const key = project ? creationKey(device.id, project.id) : ''
  const blocked = key ? engine.isBlocked(key) : true
  const tooLong = utf8Length(text) > limits.textBytes

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!project || !model || text.trim() === '' || blocked || tooLong) return
    const command = await engine.perform((owner) => commands.create({ owner, device: device.id, project: project.id }, text, { model, role: role || null }))
    if (command) {
      setText('')
      onOpen(command.chat)
    }
  }

  if (projects.length === 0) {
    return <section className="form-page"><h2>{s('newChatTitle')}</h2><p className="muted">{s('noProjects')}</p></section>
  }
  return (
    <section className="form-page">
      <form className="card" onSubmit={submit}>
        <h2>{s('newChatTitle')}</h2>
        <div className="form-grid">
          <label className="field">
            <span>{s('project')}</span>
            <select value={projectID} onChange={(event) => { setProjectID(event.target.value); setModel(''); setRole('') }}>
              {projects.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
            </select>
          </label>
          <label className="field">
            <span>{s('model')}</span>
            <select value={model} onChange={(event) => setModel(event.target.value)} disabled={models.length === 0}>
              {models.map((value) => <option key={value.id} value={value.id}>{value.name} · {agentTitle(value)}</option>)}
            </select>
          </label>
          {roles.length > 0 && (
            <label className="field">
              <span>{s('role')}</span>
              <select value={role} onChange={(event) => setRole(event.target.value)}>
                {roles.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
              </select>
            </label>
          )}
        </div>
        {models.length === 0 && <p className="small error">{s('noModels')}</p>}
        <label className="field">
          <span>{s('firstMessage')}</span>
          <textarea rows={6} value={text} placeholder={s('firstMessagePlaceholder')} onChange={(event) => setText(event.target.value)} onKeyDown={submitOnEnter} autoFocus />
        </label>
        {tooLong && <p className="small error">{s('textTooLong')}</p>}
        {key && <DeliveryNotice engine={engine} state={state} keyValue={key} />}
        {blocked && key && state.receipts.blocking(key) && <p className="small muted">{s('creationPending')}</p>}
        <div className="row end">
          <button type="button" className="ghost" onClick={onCancel}>{s('cancel')}</button>
          <button type="submit" className="primary" disabled={!model || text.trim() === '' || blocked || tooLong}>{state.inFlight.has(key) ? s('sending') : s('startChat')}</button>
        </div>
      </form>
    </section>
  )
}
