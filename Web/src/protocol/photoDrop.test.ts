import { describe, expect, it, vi, afterEach } from 'vitest'
import { isImageFile } from './photos'
import { isPhotoDrag, photoDropFiles, readPhotoDrop, transferFiles } from './photoDrop'

const file = new File(['photo'], 'windows.jpg', { type: 'image/jpeg' })
const transfer = (types: string[], files: File[] = [], items: Partial<DataTransferItem>[] = [], uri = '') => ({ types, files, items, getData: () => uri }) as unknown as DataTransfer

afterEach(() => vi.unstubAllGlobals())

describe('photo drag payloads', () => {
  it('recognizes file bytes and file items without a Files marker', () => {
    for (const data of [transfer(['Files']), transfer([], [file]), transfer([], [], [{ kind: 'file', getAsFile: () => file }])]) {
      expect(isPhotoDrag(data)).toBe(true)
    }
    expect(readPhotoDrop(transfer([], [], [{ kind: 'file', getAsFile: () => file }])).files).toEqual([file])
  })
  it('leaves plain and rich text alone but recognizes browser image URLs', () => {
    expect(isPhotoDrag(transfer(['text/plain', 'text/html']))).toBe(false)
    expect(isPhotoDrag(transfer(['text/uri-list']))).toBe(true)
    expect(readPhotoDrop(transfer(['text/uri-list'], [], [], '# comment\r\nhttps://example.com/photo.jpg\r\n')).url).toBe('https://example.com/photo.jpg')
  })
  it('prefers actual file bytes over URLs', async () => {
    const fetcher = vi.fn()
    vi.stubGlobal('fetch', fetcher)
    expect(await photoDropFiles({ files: [file], url: 'https://example.com' })).toEqual([file])
    expect(fetcher).not.toHaveBeenCalled()
  })
  it('downloads image URLs without credentials and rejects pages and unsafe schemes', async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response('image', { headers: { 'content-type': 'image/png' } }))
    vi.stubGlobal('fetch', fetcher)
    const result = await photoDropFiles({ files: [], url: 'https://example.com/photo.png' })
    expect(result[0].type).toBe('image/png')
    expect(fetcher.mock.calls[0][1]).toMatchObject({ credentials: 'omit', referrerPolicy: 'no-referrer' })
    fetcher.mockResolvedValue(new Response('<html>', { headers: { 'content-type': 'text/html' } }))
    await expect(photoDropFiles({ files: [], url: 'https://example.com/page' })).rejects.toThrow()
    for (const url of ['file:///C:/photo.jpg', 'javascript:alert(1)', '']) {
      await expect(photoDropFiles({ files: [], url })).rejects.toThrow()
    }
  })
  it('reports denied cross-origin access and excessive image sizes', async () => {
    const fetcher = vi.fn().mockRejectedValue(new TypeError('CORS'))
    vi.stubGlobal('fetch', fetcher)
    await expect(photoDropFiles({ files: [], url: 'https://example.com/photo.png' })).rejects.toThrow('CORS')
    fetcher.mockResolvedValue(new Response('x', { headers: { 'content-type': 'image/png', 'content-length': String(41 * 1024 * 1024) } }))
    await expect(photoDropFiles({ files: [], url: 'https://example.com/photo.png' })).rejects.toThrow('image response')
  })
})


describe('Windows copied photo files', () => {
  it('reads FileList even when no typed clipboard items exist', () => {
    const photo = new File(['png'], 'camera.PNG', { type: '' })
    expect(transferFiles(transfer(['Files'], [photo]))).toEqual([photo])
    expect(isImageFile(photo)).toBe(true)
  })
  it('accepts untyped file items and octet-stream photos, then requires decoder validation', () => {
    const photo = new File(['jpeg'], 'camera.jpeg', { type: 'application/octet-stream' })
    expect(transferFiles(transfer(['Files'], [], [{ kind: 'file', type: '', getAsFile: () => photo }]))).toEqual([photo])
    expect(isImageFile(photo)).toBe(true)
    expect(isImageFile({ name: 'script.exe', type: '' })).toBe(false)
    expect(isImageFile({ name: 'notes.txt', type: 'text/plain' })).toBe(false)
    expect(transferFiles(transfer(['text/plain']))).toEqual([])
  })
})
