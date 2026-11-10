/** Drag payloads vary between Explorer, browser tabs and image viewers. */
export function isPhotoDrag(data: Pick<DataTransfer, 'types' | 'items' | 'files'> | null): boolean {
  return Boolean(data && (Array.from(data.types).some(type => ['Files', 'text/uri-list'].includes(type))
    || data.files.length || Array.from(data.items).some(item => item.kind === 'file')))
}

/** Shared by paste and drop: Windows can expose files without an image MIME type. */
export function transferFiles(data: Pick<DataTransfer, 'files' | 'items'>): File[] {
  const files = Array.from(data.files)
  if (!files.length) {
    for (const item of Array.from(data.items)) {
      if (item.kind === 'file') {
        const file = item.getAsFile()
        if (file) files.push(file)
      }
    }
  }
  return files
}

/** Read during the drop event, before the browser protects the data store again. */
export function readPhotoDrop(data: DataTransfer): { files: File[]; url: string } {
  const files = transferFiles(data)
  const url = data.getData('text/uri-list').split(/\r?\n/).map(line => line.trim()).find(line => line && !line.startsWith('#')) ?? ''
  return { files, url }
}

/** A dragged browser image may contain a URL instead of file bytes. Never navigate to it. */
export async function photoDropFiles(payload: ReturnType<typeof readPhotoDrop>): Promise<File[]> {
  if (payload.files.length) return payload.files
  const url = new URL(payload.url)
  if (url.protocol !== 'https:' && !(url.protocol === 'data:' && payload.url.startsWith('data:image/'))) throw new Error('image URL')
  const response = await fetch(url, { credentials: 'omit', signal: AbortSignal.timeout(20_000), referrerPolicy: 'no-referrer' })
  const type = response.headers.get('content-type')?.split(';')[0] ?? ''
  const maximum = 40 * 1024 * 1024
  if (!response.ok || !type.startsWith('image/') || Number(response.headers.get('content-length')) > maximum) throw new Error('image response')
  const reader = response.body?.getReader()
  if (!reader) throw new Error('image response')
  const chunks: Uint8Array<ArrayBuffer>[] = []
  let size = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > maximum) throw new Error('image size')
      chunks.push(value)
    }
  } finally { await reader.cancel() }
  return [new File(chunks, 'dropped-image', { type })]
}
