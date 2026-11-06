// `switchboard-chat:<chat id>` links in the answers of archive-search chats.
import { Lexer, type Token, type Tokens } from 'marked'

export const chatLinkScheme = 'switchboard-chat:'

export interface ChatLink {
  id: string
  title: string
}

/** The chat ID of a `switchboard-chat:` href, or null when the href is not one or is malformed. */
export function chatLinkID(href: string | null | undefined): string | null {
  if (!href) return null
  const value = href.trim()
  if (!value.toLowerCase().startsWith(chatLinkScheme)) return null
  let id = value.slice(chatLinkScheme.length).replace(/^\/\//, '')
  try {
    id = decodeURIComponent(id)
  } catch {
    return null
  }
  id = id.trim()
  if (!id || id.length > 500 || /[\s\u0000-\u001f<>"]/.test(id)) return null
  return id
}

function walk(tokens: Token[] | undefined, found: ChatLink[]): void {
  for (const token of tokens ?? []) {
    if (token.type === 'link') {
      const link = token as Tokens.Link
      const id = chatLinkID(link.href)
      if (id) found.push({ id, title: link.text.trim() || id })
      continue
    }
    const nested = token as { tokens?: Token[]; items?: Token[] }
    if (nested.tokens) walk(nested.tokens, found)
    if (token.type === 'list') for (const item of (token as Tokens.List).items) walk(item.tokens, found)
    if (token.type === 'table') {
      const table = token as Tokens.Table
      for (const cell of table.header) walk(cell.tokens, found)
      for (const row of table.rows) for (const cell of row) walk(cell.tokens, found)
    }
  }
}

/** Every chat link of a Markdown text in order, each chat once (first title wins). Code is ignored. */
export function extractChatLinks(markdown: string): ChatLink[] {
  const found: ChatLink[] = []
  walk(new Lexer({ gfm: true }).lex(markdown), found)
  const seen = new Set<string>()
  return found.filter((link) => (seen.has(link.id) ? false : (seen.add(link.id), true)))
}
