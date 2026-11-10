import type { RemotePhoto } from './types'

/** Unknown Windows file types are accepted by name, then verified by the image decoder. */
export function isImageFile(file: Pick<File, 'name' | 'type'>): boolean {
  return file.type.startsWith('image/') || ((!file.type || file.type === 'application/octet-stream')
    && /\.(jpe?g|png|webp|gif|bmp|avif|heic|heif|tiff?|ico)$/i.test(file.name))
}

/** Decode locally, resize, and encode the JPEG payload used by the iPhone protocol. */
export async function preparePhoto(file: File): Promise<RemotePhoto> {
  if (!isImageFile(file) || file.size > 40 * 1024 * 1024) throw new Error('image')
  const url = URL.createObjectURL(file)
  try {
    const image = new Image()
    image.src = url
    await image.decode()
    const scale = Math.min(1, 2048 / Math.max(image.naturalWidth, image.naturalHeight))
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale))
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale))
    const context = canvas.getContext('2d')
    if (!context) throw new Error('canvas')
    context.fillStyle = '#fff'
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.drawImage(image, 0, 0, canvas.width, canvas.height)
    for (const quality of [0.85, 0.7, 0.5, 0.3, 0.15]) {
      const data = canvas.toDataURL('image/jpeg', quality).split(',')[1]
      if (atob(data).length <= 512 * 1024) return { id: crypto.randomUUID(), data }
    }
    throw new Error('size')
  } finally { URL.revokeObjectURL(url) }
}
