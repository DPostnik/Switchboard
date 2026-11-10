// These fixed functions execute in a debugger-created isolated world. No caller code is evaluated.
export function observePage(args) {
  const key = '__switchboard_page_v1__';
  const state = globalThis[key] ||= {token: crypto.randomUUID(), next: 0, refs: new Map(), elements: new WeakMap()};
  const ref = el => {
    let value = state.elements.get(el);
    if (!value) { value = `ref_${++state.next}`; state.elements.set(el, value); state.refs.set(value, new WeakRef(el)); }
    return value;
  };
  const clip = (value, max) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, max);
  const controls = [];
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  const texts = [];
  let nodes = 0, length = 0, node, truncated = false;
  const start = performance.now();
  while ((node = walker.nextNode())) {
    if (++nodes > 5000 || length >= 24000 || performance.now() - start > 100) { truncated = true; break; }
    const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    if (!el || el.closest('script,style,noscript,template,textarea,[hidden],[aria-hidden="true"]')) continue;
    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') continue;
    if (node.nodeType === Node.TEXT_NODE) {
      const text = clip(node.nodeValue, 24000 - length);
      if (text) { texts.push(text); length += text.length + 1; }
    } else if (controls.length < 200 && el.matches('button,a[href],input,textarea,select,[role],[contenteditable="true"]')) {
      const sensitive = el.matches('input[type="password"],input[type="hidden"]') || /password|one-time-code|cc-/.test(el.autocomplete || '');
      controls.push({ref: ref(el), tag: el.tagName.toLowerCase(), role: clip(el.getAttribute('role'), 60),
        name: clip(el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.innerText || el.getAttribute('placeholder'), 240),
        type: clip(el.type, 30), disabled: !!el.disabled, sensitive});
    }
  }
  const text = texts.join('\n');
  const query = String(args.query || '').slice(0, 500);
  return {url: location.href, title: document.title.slice(0, 500), documentToken: state.token, text,
    controls: query ? controls.filter(x => x.name.toLowerCase().includes(query.toLowerCase())) : controls,
    matches: query ? text.toLowerCase().indexOf(query.toLowerCase()) : undefined,
    frames: [...document.querySelectorAll('iframe,frame')].slice(0, 50).map(el => ({ref: ref(el), src: el.src})),
    truncated, omitted: ['closed_shadow_roots', 'form_values', 'canvas_contents']};
}

export function resolveElement(args) {
  const state = globalThis.__switchboard_page_v1__;
  if (!state || state.token !== args.documentToken) throw new Error('stale_document');
  const el = state.refs.get(args.ref)?.deref();
  if (!el?.isConnected) throw new Error('stale_ref');
  if (el.matches('input[type="password"],input[type="hidden"]') || /password|one-time-code|cc-/.test(el.autocomplete || '')) throw new Error('sensitive_input');
  el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
  const rect = el.getBoundingClientRect();
  if (!rect.width || !rect.height || el.disabled) throw new Error('element_unavailable');
  const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
  if (!hit || !(el === hit || el.contains(hit))) throw new Error('element_obscured');
  if (args.focus) el.focus({preventScroll: true});
  return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
}

export function installUpload(args) {
  const state = globalThis.__switchboard_page_v1__;
  if (!state || state.token !== args.documentToken) throw new Error('stale_document');
  const el = state.refs.get(args.ref)?.deref();
  if (!el?.isConnected || !el.matches('input[type="file"]') || el.disabled) throw new Error('file_input_required');
  if (!el.multiple && args.files.length !== 1) throw new Error('single_file_required');
  const transfer = new DataTransfer();
  for (const file of args.files) {
    const bytes = Uint8Array.from(atob(file.base64), char => char.charCodeAt(0));
    transfer.items.add(new File([bytes], file.name, {type: file.mimeType}));
  }
  el.files = transfer.files;
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return {uploaded: transfer.files.length};
}
