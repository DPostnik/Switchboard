// Agent text is data: rendered as sanitized Markdown, never as HTML.
import DOMPurify from 'dompurify'
import { Marked, type Tokens } from 'marked'
import { chatLinkID, chatLinkScheme } from '../protocol/links'

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]!)
}

export interface ChatLinkRender {
  /** Button label for one linked chat. */
  label(id: string): string
  disabled(id: string): boolean
}

/** Per-render options; parsing is synchronous, so a module slot is safe. */
let chatLinks: ChatLinkRender | null = null

const marked = new Marked({ gfm: true, breaks: false, async: false })
marked.use({
  renderer: {
    // Raw HTML in agent text is shown as text.
    html(token: Tokens.HTML | Tokens.Tag) {
      return escapeHTML(token.text)
    },
    link(token: Tokens.Link) {
      if (!token.href.trim().toLowerCase().startsWith(chatLinkScheme)) return false
      const label = this.parser.parseInline(token.tokens)
      const id = chatLinkID(token.href)
      if (!id || !chatLinks) return `<span class="chat-link">${label}</span>`
      const disabled = chatLinks.disabled(id) ? ' disabled' : ''
      return `<span class="chat-link"><span class="chat-link-title">${label}</span> <button type="button" class="restore-button" data-restore="${escapeHTML(id)}"${disabled}>${escapeHTML(chatLinks.label(id))}</button></span>`
    },
    // Remote images are not loaded: shown as a link.
    image(token: Tokens.Image) {
      const text = escapeHTML(token.text || token.href)
      return /^https?:/i.test(token.href) ? `<a href="${escapeHTML(token.href)}">${text}</a>` : text
    },
  },
})

let hooked = false
function purifier(): typeof DOMPurify {
  if (!hooked) {
    hooked = true
    DOMPurify.addHook('afterSanitizeAttributes', (node) => {
      if (node.tagName === 'A') {
        node.setAttribute('target', '_blank')
        node.setAttribute('rel', 'noopener noreferrer nofollow')
      }
    })
  }
  return DOMPurify
}

export function renderMarkdown(text: string, links: ChatLinkRender | null = null): string {
  chatLinks = links
  try {
    const html = marked.parse(text) as string
    return purifier().sanitize(html, {
      ADD_ATTR: ['target'],
      FORBID_TAGS: ['style', 'img', 'form', 'iframe', 'video', 'audio', 'svg', 'math'],
      ALLOW_DATA_ATTR: true,
    })
  } finally {
    chatLinks = null
  }
}
