import { describe, expect, it } from 'vitest'
import { chatLinkID, extractChatLinks } from './links'

describe('switchboard-chat links', () => {
  it('extracts chat links with titles in order, each chat once', () => {
    const text = [
      'Found two chats:',
      '',
      '1. [Vercel deploy](switchboard-chat:019a7b2c-1111-7222-8333-444455556666) — October',
      '2. [Mobile **relay**](switchboard-chat:mobile%3Aabc) and a [doc](https://example.com)',
      '',
      '| Chat | When |',
      '| --- | --- |',
      '| [Table chat](switchboard-chat:web:xyz) | today |',
      '',
      'Again: [Vercel deploy again](switchboard-chat:019a7b2c-1111-7222-8333-444455556666)',
    ].join('\n')
    expect(extractChatLinks(text)).toEqual([
      { id: '019a7b2c-1111-7222-8333-444455556666', title: 'Vercel deploy' },
      { id: 'mobile:abc', title: 'Mobile **relay**' },
      { id: 'web:xyz', title: 'Table chat' },
    ])
  })

  it('ignores links inside code', () => {
    expect(extractChatLinks('```\n[x](switchboard-chat:abc)\n```\n`[y](switchboard-chat:def)`')).toEqual([])
  })

  it('parses only well-formed chat hrefs', () => {
    expect(chatLinkID('switchboard-chat:abc')).toBe('abc')
    expect(chatLinkID('SWITCHBOARD-CHAT://abc')).toBe('abc')
    expect(chatLinkID('switchboard-chat:')).toBeNull()
    expect(chatLinkID('switchboard-chat:a%20b')).toBeNull()
    expect(chatLinkID('switchboard-chat:%E0%A4%A')).toBeNull()
    expect(chatLinkID('https://example.com')).toBeNull()
    expect(chatLinkID('switchboard-chat:' + 'x'.repeat(501))).toBeNull()
  })
})
