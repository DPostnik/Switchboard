import { useEffect, useRef, useState, type ClipboardEvent } from 'react'
import { isPhotoDrag, readPhotoDrop, photoDropFiles, transferFiles } from '../protocol/photoDrop'
import { preparePhoto } from '../protocol/photos'
import type { RemotePhoto } from '../protocol/types'

const photoDrafts = new Map<string, RemotePhoto[]>()

/** One attachment path for both first messages and existing chats. */
export function usePhotoAttachments(key: string, enabled: boolean, isBlocked: () => boolean) {
  const [draft, setPhotosState] = useState<{ key: string; photos: RemotePhoto[] }>(() => ({ key, photos: photoDrafts.get(key) ?? [] }))
  const photos = draft.key === key ? draft.photos : photoDrafts.get(key) ?? []
  const [loadingPhotos, setLoadingPhotos] = useState(false)
  const [photoError, setPhotoError] = useState<'photoError' | 'photoDropHelp' | null>(null)
  const [draggingPhotos, setDraggingPhotos] = useState(false)
  const dragDepth = useRef(0)
  const fileDragActive = useRef(false)
  const choosing = useRef(false)
  const picker = useRef<HTMLInputElement>(null)
  const setPhotos = (value: RemotePhoto[]) => { photoDrafts.set(key, value); setPhotosState({ key, photos: value }) }
  const addPhotos = async (source: File[] | (() => Promise<File[]>)) => {
    if (choosing.current || isBlocked()) return
    choosing.current = true
    setLoadingPhotos(true)
    setPhotoError(null)
    try {
      const files = typeof source === 'function' ? await source() : source
      if (!files.length) throw new Error('empty drop')
      if (files.length + photos.length > 4) throw new Error('count')
      const added: RemotePhoto[] = []
      for (const file of files) added.push(await preparePhoto(file))
      setPhotos([...photos, ...added])
    } catch { setPhotoError(typeof source === 'function' ? 'photoDropHelp' : 'photoError') }
    finally { choosing.current = false; setLoadingPhotos(false) }
  }
  // File drops must not navigate the tab. Only the active writable chat accepts them.
  useEffect(() => {
    const isFiles = (event: DragEvent) => isPhotoDrag(event.dataTransfer) || fileDragActive.current
    const accepts = (event: DragEvent) => event.target instanceof Element
      && Boolean(event.target.closest('.chat')) && enabled && !isBlocked() && !choosing.current
    const enter = (event: DragEvent) => {
      if (!isFiles(event)) return
      event.preventDefault()
      fileDragActive.current = true
      dragDepth.current++
      if (accepts(event)) setDraggingPhotos(true)
    }
    const over = (event: DragEvent) => {
      if (!isFiles(event)) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = accepts(event) ? 'copy' : 'none'
      setDraggingPhotos(accepts(event))
    }
    const leave = (event: DragEvent) => {
      if (!isFiles(event)) return
      dragDepth.current = Math.max(0, dragDepth.current - 1)
      if (!dragDepth.current) { fileDragActive.current = false; setDraggingPhotos(false) }
    }
    const drop = (event: DragEvent) => {
      if (!isFiles(event)) return
      event.preventDefault()
      // Cancel native opening before any descendant can consume or stop the drop.
      event.stopPropagation()
      fileDragActive.current = false
      dragDepth.current = 0
      setDraggingPhotos(false)
      if (accepts(event) && event.dataTransfer) {
        const payload = readPhotoDrop(event.dataTransfer)
        void addPhotos(() => photoDropFiles(payload))
      }
    }
    const end = () => { fileDragActive.current = false; dragDepth.current = 0; setDraggingPhotos(false) }
    window.addEventListener('dragenter', enter, true)
    window.addEventListener('dragover', over, true)
    window.addEventListener('dragleave', leave, true)
    window.addEventListener('drop', drop, true)
    window.addEventListener('dragend', end)
    window.addEventListener('blur', end)
    return () => {
      window.removeEventListener('dragenter', enter, true)
      window.removeEventListener('dragover', over, true)
      window.removeEventListener('dragleave', leave, true)
      window.removeEventListener('drop', drop, true)
      window.removeEventListener('dragend', end)
      window.removeEventListener('blur', end)
    }
  })

  const onPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    // Explorer's Copy file may supply FileList or untyped file items.
    const images = transferFiles(event.clipboardData)
    if (!images.length) {
      if (Array.from(event.clipboardData.types).includes('Files')) {
        event.preventDefault()
        setPhotoError('photoDropHelp')
      }
      return
    }
    event.preventDefault()
    if (enabled) void addPhotos(images)
  }
  const clearSent = (sent: RemotePhoto[]) => { if (photoDrafts.get(key) === sent) setPhotos([]) }
  return { photos, setPhotos, loadingPhotos, photoError, draggingPhotos, picker, addPhotos, onPaste, clearSent }
}
