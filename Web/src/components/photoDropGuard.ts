import { isPhotoDrag } from '../protocol/photoDrop'

/** Installed before React: a missing/loading composer must never allow file navigation. */
export function installPhotoDropGuard(): void {
  for (const type of ['dragover', 'drop']) {
    window.addEventListener(type, event => {
      if (isPhotoDrag((event as DragEvent).dataTransfer)) event.preventDefault()
    }, true)
  }
}
