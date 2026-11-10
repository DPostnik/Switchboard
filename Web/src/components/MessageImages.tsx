import { useEffect, useState } from 'react'
import { s } from '../i18n/strings'
import type { RemoteImage } from '../protocol/types'

const extensions: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif' }

/** Only host-delivered raster bytes are displayed. Agent Markdown cannot load arbitrary URLs. */
function imageURL(image: RemoteImage): string | null {
  if (!image || !['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(image.mimeType)
    || typeof image.data !== 'string' || image.data.length > 300_000
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.data)) return null
  try {
    const bytes = Uint8Array.from(atob(image.data), char => char.charCodeAt(0))
    return URL.createObjectURL(new Blob([bytes], { type: image.mimeType }))
  } catch { return null }
}

function ImagePreview({ image, onLoad }: { image: RemoteImage; onLoad?: () => void }) {
  const [url, setURL] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    const value = imageURL(image)
    setURL(value)
    setLoaded(false)
    setFailed(value === null)
    return () => { if (value) URL.revokeObjectURL(value) }
  }, [image.data, image.mimeType])
  if (failed) return <p className="message-note error" role="status">{s('imageUnavailable')}</p>
  return <figure className="message-image">
    {!loaded && <p className="message-note" role="status">{s('loadingImage')}</p>}
    {url && <>
      <a href={url} target="_blank" rel="noopener noreferrer" aria-label={s('openImage')}>
        <img src={url} alt={image.name || s('attachedPhoto')} onLoad={() => { setLoaded(true); onLoad?.() }} onError={() => setFailed(true)} />
      </a>
      {loaded && <figcaption><a href={url} download={'preview.' + (extensions[image.mimeType] ?? 'jpg')}>{s('downloadPreview')}</a></figcaption>}
    </>}
  </figure>
}

export function MessageImages({ images, imageError, onLoad }: { images?: RemoteImage[] | null; imageError?: boolean | null; onLoad?: () => void }) {
  return <>
    {Array.isArray(images) && images.slice(0, 4).filter(image => image && typeof image.data === 'string').map((image, index) => <ImagePreview key={image.id || index} image={image} onLoad={onLoad} />)}
    {imageError && <p className="message-note error" role="status">{s('imageUnavailable')}</p>}
  </>
}
