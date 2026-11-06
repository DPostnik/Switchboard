import { useRef, useState, type FormEvent } from 'react'
import { s } from '../i18n/strings'
import { commands, limits } from '../protocol/commands'
import { creationKey } from '../protocol/receipts'
import type { RemoteDevice } from '../protocol/types'
import type { EngineState } from '../sync/engine'
import { useAutosize } from './Composer'
import { DeliveryNotice } from './Dock'
import { EmptyState } from './EmptyState'
import type { EngineLike } from './engineLike'
import { Icon } from './Icon'
import { submitOnEnter } from './keys'
import { cancelOnEscape, ChipSelect, FormPage } from './NewChatForm'

interface Props {
  engine: EngineLike
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
  const field = useRef<HTMLTextAreaElement>(null)
  useAutosize(field, text)
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
    return (
      <FormPage title={s('searchTitle')} onCancel={onCancel}>
        <EmptyState icon="search" title={s('searchTitle')} text={s('noSearchProjects')} />
      </FormPage>
    )
  }
  return (
    <FormPage title={s('searchTitle')} subtitle={project?.name} onCancel={onCancel}>
      <EmptyState icon="search" title={s('searchTitle')} text={s('searchLead')} />
      <form className="dock" onSubmit={submit} onKeyDown={cancelOnEscape(onCancel)}>
        {tooLong && <div className="composer-note bad" role="alert">{s('searchTooLong')}</div>}
        {key && <DeliveryNotice engine={engine} state={state} keyValue={key} />}
        <div className="composer">
          <textarea ref={field} className="composer-input" rows={1} value={text} placeholder={s('searchPlaceholder')} aria-label={s('searchRequest')}
            onChange={(event) => setText(event.target.value)} onKeyDown={submitOnEnter} autoFocus />
          <div className="composer-bar">
            <ChipSelect icon="folder" label={s('project')} value={projectID} onChange={setProjectID}>
              {projects.map((value) => <option key={value.id} value={value.id}>{value.name}</option>)}
            </ChipSelect>
            <span className="composer-spacer" />
            <button type="submit" className="round-button" disabled={text.trim() === '' || blocked || tooLong}
              aria-label={s('startSearch')} title={s('startSearch')} aria-busy={state.inFlight.has(key) || undefined}>
              <Icon name="search" size={15} />
            </button>
          </div>
        </div>
      </form>
    </FormPage>
  )
}
