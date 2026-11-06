import { useState, type FormEvent } from 'react'
import { s } from '../i18n/strings'
import { commands, limits } from '../protocol/commands'
import { creationKey } from '../protocol/receipts'
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

/** "Find in archive": starts a read-only chat-search agent on the Mac in the chosen project. */
export function SearchForm({ engine, state, device, initialProject, onOpen, onCancel }: Props) {
  const projects = device.snapshot.projects.filter((project) => project.canUseWeb === true && project.canSearchChats === true)
  const [projectID, setProjectID] = useState(() => (projects.some((project) => project.id === initialProject) ? initialProject : projects[0]?.id ?? ''))
  const project = projects.find((value) => value.id === projectID)
  const [text, setText] = useState('')
  const key = project ? creationKey(device.id, project.id) : ''
  const blocked = key ? engine.isBlocked(key) : true
  const tooLong = [...text.trim()].length > limits.searchCharacters

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!project || text.trim() === '' || blocked || tooLong) return
    const command = await engine.perform((owner) => commands.search({ owner, device: device.id, project: project.id }, text))
    if (command) {
      setText('')
      onOpen(command.chat)
    }
  }

  if (projects.length === 0) {
    return <section className="form-page"><h2>{s('searchTitle')}</h2><p className="muted">{s('noSearchProjects')}</p></section>
  }
  return (
    <section className="form-page">
      <form className="card" onSubmit={submit}>
        <h2>{s('searchTitle')}</h2>
        <p className="muted small">{s('searchLead')}</p>
        <label className="field">
          <span>{s('project')}</span>
          <select value={projectID} onChange={(event) => setProjectID(event.target.value)}>
            {projects.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
          </select>
        </label>
        <label className="field">
          <span>{s('searchRequest')}</span>
          <textarea rows={4} value={text} placeholder={s('searchPlaceholder')} onChange={(event) => setText(event.target.value)} onKeyDown={submitOnEnter} autoFocus />
        </label>
        {tooLong && <p className="small error">{s('searchTooLong')}</p>}
        {key && <DeliveryNotice engine={engine} state={state} keyValue={key} />}
        <div className="row end">
          <button type="button" className="ghost" onClick={onCancel}>{s('cancel')}</button>
          <button type="submit" className="primary" disabled={text.trim() === '' || blocked || tooLong}>{state.inFlight.has(key) ? s('sending') : s('startSearch')}</button>
        </div>
      </form>
    </section>
  )
}
