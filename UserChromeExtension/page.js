// These fixed functions execute in a debugger-created isolated world. No caller code is evaluated.
// Each function is serialized on its own (Function.prototype.toString), so it must not use
// module-level helpers: shared rules are repeated inside every function that needs them.

export function observePage(args) {
  const key = '__switchboard_page_v1__';
  const state = globalThis[key] ||= {token: crypto.randomUUID(), next: 0, refs: new Map(), elements: new WeakMap()};
  const ref = el => {
    let value = state.elements.get(el);
    if (!value) { value = `ref_${++state.next}`; state.elements.set(el, value); state.refs.set(value, new WeakRef(el)); }
    return value;
  };
  const clip = (value, max) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, max);
  const sensitiveOf = el => el.matches('input[type="password"],input[type="hidden"]') ||
    /password|one-time-code|cc-/.test(el.getAttribute('autocomplete') || '');
  // Text of the elements named by an ID list attribute (aria-labelledby, aria-describedby, aria-errormessage).
  const textOf = ids => clip(String(ids || '').split(/\s+/).filter(Boolean).slice(0, 5)
    .map(id => { const el = document.getElementById(id); return el ? el.innerText || el.textContent : ''; }).join(' '), 300);
  const nameOf = el => clip(el.getAttribute('aria-label') || textOf(el.getAttribute('aria-labelledby')) ||
    el.labels?.[0]?.innerText || (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? '' : el.innerText) ||
    el.getAttribute('title') || el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('name'), 240);
  const describe = el => {
    const sensitive = sensitiveOf(el);
    const control = {ref: ref(el), tag: el.tagName.toLowerCase(), role: clip(el.getAttribute('role'), 60), name: nameOf(el),
      type: clip(el.getAttribute('type') || (el.tagName === 'BUTTON' ? 'submit' : ''), 30), disabled: !!el.disabled, sensitive};
    if (el.tagName === 'A' && el.href) control.href = clip(el.href, 300);
    // Form state for non-sensitive controls only; sensitive values never leave the page.
    if (!sensitive) {
      if (el.tagName === 'SELECT') control.value = [...el.selectedOptions].slice(0, 10).map(o => clip(o.label, 120)).join(', ');
      else if (el.tagName === 'TEXTAREA') control.value = clip(el.value, 500);
      else if (el.tagName === 'INPUT') {
        const type = (el.type || 'text').toLowerCase();
        if (type === 'checkbox' || type === 'radio') control.checked = !!el.checked;
        else if (type === 'file') control.value = [...(el.files || [])].slice(0, 10).map(f => clip(f.name, 120)).join(', ');
        else if (!['submit', 'button', 'reset', 'image'].includes(type)) control.value = clip(el.value, 200);
      }
      if (el.getAttribute('role') === 'checkbox' || el.getAttribute('role') === 'switch' || el.getAttribute('role') === 'radio') {
        control.checked = el.getAttribute('aria-checked') === 'true';
      }
    }
    if (el.required || el.getAttribute('aria-required') === 'true') control.required = true;
    let invalid = el.getAttribute('aria-invalid') === 'true';
    try { invalid ||= el.matches(':user-invalid'); } catch {}
    if (invalid) {
      control.invalid = true;
      const message = textOf(el.getAttribute('aria-errormessage')) || clip(el.validationMessage, 200);
      if (message) control.error = message;
    }
    const description = textOf(el.getAttribute('aria-describedby'));
    if (description) control.description = clip(description, 200);
    return control;
  };
  const controls = [];
  const texts = [];
  let nodes = 0, length = 0, truncated = false;
  const start = performance.now();
  const selector = 'button,a[href],input,textarea,select,[role],[contenteditable="true"],[contenteditable=""]';
  // Walk the document and every open shadow root in document order, within one shared budget.
  const walk = root => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (++nodes > 5000 || length >= 24000 || performance.now() - start > 100) { truncated = true; return; }
      const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      if (!el || el.closest('script,style,noscript,template,[hidden],[aria-hidden="true"]')) continue;
      if (node.nodeType === Node.TEXT_NODE && el.closest('textarea')) continue;
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') continue;
      if (node.nodeType === Node.TEXT_NODE) {
        const text = clip(node.nodeValue, 24000 - length);
        if (text) { texts.push(text); length += text.length + 1; }
        continue;
      }
      if (controls.length < 200 && el.matches(selector)) controls.push(describe(el));
      if (el.shadowRoot) { walk(el.shadowRoot); if (truncated) return; }
    }
  };
  walk(document.body || document.documentElement);
  const alerts = [...document.querySelectorAll('[role="alert"],[aria-live="assertive"]')].slice(0, 20)
    .map(el => clip(el.innerText, 300)).filter(Boolean).slice(0, 10);
  const text = texts.join('\n');
  const query = String(args.query || '').slice(0, 500);
  let found = controls;
  if (query) {
    // Lexical ranking over role, tag, type, name, value, description and link address (ru/en).
    const norm = value => String(value || '').toLowerCase().replace(/ё/g, 'е');
    const words = value => norm(value).match(/[\p{L}\p{N}]+/gu) || [];
    const stem = word => word.length >= 5 ? word.slice(0, 5) : word;
    const roles = {button: ['button', 'btn', 'кнопка', 'кнопку'], link: ['link', 'ссылка', 'ссылку'],
      textbox: ['field', 'input', 'textbox', 'поле', 'ввод'], checkbox: ['checkbox', 'галочка', 'флажок', 'чекбокс'],
      radio: ['radio', 'переключатель'], combobox: ['select', 'dropdown', 'combobox', 'список']};
    const roleOf = control => control.role || (control.tag === 'a' ? 'link' : control.tag === 'button' ? 'button' :
      control.tag === 'select' ? 'combobox' : control.tag === 'textarea' ? 'textbox' :
      control.tag === 'input' ? (['checkbox', 'radio'].includes(control.type) ? control.type :
        ['submit', 'button', 'reset', 'image'].includes(control.type) ? 'button' : 'textbox') : control.tag);
    const tokens = words(query);
    const roleTokens = new Set(tokens.filter(t => Object.values(roles).some(list => list.includes(t))));
    const plain = tokens.filter(t => !roleTokens.has(t));
    found = controls.map((control, order) => {
      const body = words([control.name, control.value, control.description, control.href, control.type].join(' '));
      const stems = new Set(body.map(stem));
      let score = 0, hits = 0;
      for (const token of plain) {
        const hit = body.includes(token) ? 1 : stems.has(stem(token)) ? 0.6 : body.some(w => w.includes(token)) ? 0.4 : 0;
        score += hit; if (hit) hits++;
      }
      const roleHit = [...roleTokens].some(t => (roles[roleOf(control)] || []).includes(t));
      if (roleHit) score += 1;
      if ((plain.length && !hits) || (!plain.length && !roleHit)) return null;
      return {control, score: score / Math.max(tokens.length, 1), order};
    }).filter(Boolean).sort((a, b) => b.score - a.score || a.order - b.order).slice(0, 50)
      .map(({control, score}) => ({...control, score: Math.round(score * 100) / 100}));
  }
  return {url: location.href, title: document.title.slice(0, 500), documentToken: state.token, text,
    controls: found, alerts,
    matches: query ? text.toLowerCase().indexOf(query.toLowerCase()) : undefined,
    frames: [...document.querySelectorAll('iframe,frame')].slice(0, 50).map(el => ({ref: ref(el), src: el.src})),
    truncated, omitted: ['closed_shadow_roots', 'sensitive_field_values', 'canvas_contents']};
}

// The document token, URL and device pixel ratio without walking the page.
export function pageInfo() {
  const key = '__switchboard_page_v1__';
  const state = globalThis[key] ||= {token: crypto.randomUUID(), next: 0, refs: new Map(), elements: new WeakMap()};
  return {documentToken: state.token, url: location.href, devicePixelRatio: devicePixelRatio || 1,
    viewport: {width: innerWidth, height: innerHeight}};
}

export function resolveElement(args) {
  const state = globalThis.__switchboard_page_v1__;
  if (!state || state.token !== args.documentToken) throw new Error('stale_document');
  const el = state.refs.get(args.ref)?.deref();
  if (!el?.isConnected) throw new Error('stale_ref');
  if (el.matches('input[type="password"],input[type="hidden"]') || /password|one-time-code|cc-/.test(el.getAttribute('autocomplete') || '')) throw new Error('sensitive_input');
  // A click on a file field opens the native picker, which cannot be operated; upload exists for it.
  if (args.click && (el.matches('input[type="file"]') || el.control?.type === 'file')) throw new Error('file_input_use_upload');
  el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
  const rect = el.getBoundingClientRect();
  if (!rect.width || !rect.height || (!args.allowDisabled && el.disabled)) throw new Error('element_unavailable');
  const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
  if (!args.allowObscured) {
    const root = el.getRootNode();
    const hit = (root.elementFromPoint ? root : document).elementFromPoint(x, y);
    const covered = !hit || !(el === hit || el.contains(hit) || hit.control === el || (hit.tagName === 'LABEL' && hit.contains(el)) ||
      (hit.shadowRoot && hit.contains(el)));
    if (covered) throw new Error('element_obscured');
  }
  if (args.focus) el.focus({preventScroll: true});
  const type = (el.getAttribute('type') || '').toLowerCase();
  const role = el.getAttribute('role') || '';
  const checkable = (el.tagName === 'INPUT' && ['checkbox', 'radio'].includes(type)) || ['checkbox', 'switch', 'radio'].includes(role);
  return {x, y, tag: el.tagName.toLowerCase(), type: type || role,
    ...(checkable ? {checked: el.tagName === 'INPUT' ? !!el.checked : el.getAttribute('aria-checked') === 'true'} : {})};
}

// Classify the element under a viewport point, through same-origin frames and open shadow roots.
export function inspectPoint(args) {
  let doc = document, x = args.x, y = args.y, element = doc.elementFromPoint(x, y);
  while (element) {
    if (element.shadowRoot) {
      const inner = element.shadowRoot.elementFromPoint(x, y);
      if (inner && inner !== element) { element = inner; continue; }
    }
    if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
      let inner = null;
      try { inner = element.contentDocument; } catch {}
      if (!inner) return {crossFrame: true};
      const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
      x -= rect.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
      y -= rect.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop);
      doc = inner;
      const next = doc.elementFromPoint(x, y);
      if (!next) break;
      element = next;
      continue;
    }
    break;
  }
  if (!element) return {found: false};
  const field = element.closest('input,textarea,select') || (element.tagName === 'LABEL' ? element.control : null);
  const sensitive = !!field && (field.matches('input[type="password"],input[type="hidden"]') ||
    /password|one-time-code|cc-/.test(field.getAttribute('autocomplete') || ''));
  const file = !!field?.matches('input[type="file"]') || element.closest('label')?.control?.type === 'file';
  return {found: true, tag: element.tagName.toLowerCase(), sensitive, file};
}

// The focused element, through open shadow roots and same-origin frames.
export function inspectFocus() {
  if (!document.hasFocus()) return {focused: false};
  let element = document.activeElement;
  while (element) {
    if (element.shadowRoot?.activeElement) { element = element.shadowRoot.activeElement; continue; }
    if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
      let inner = null;
      try { inner = element.contentDocument; } catch {}
      if (!inner) return {focused: true, crossFrame: true};
      element = inner.activeElement;
      continue;
    }
    break;
  }
  if (!element || element === element.ownerDocument.body || element === element.ownerDocument.documentElement) return {focused: false};
  const sensitive = element.matches('input[type="password"],input[type="hidden"]') ||
    /password|one-time-code|cc-/.test(element.getAttribute('autocomplete') || '');
  const editable = element.isContentEditable || element.tagName === 'TEXTAREA' ||
    (element.tagName === 'INPUT' && !['checkbox', 'radio', 'file', 'submit', 'button', 'reset', 'image', 'range', 'color'].includes((element.type || '').toLowerCase())) ||
    ['textbox', 'searchbox', 'combobox'].includes(element.getAttribute('role'));
  return {focused: true, crossFrame: false, sensitive, editable, tag: element.tagName.toLowerCase()};
}

// Select an option of a native <select> by its visible label or value.
export function selectOption(args) {
  const state = globalThis.__switchboard_page_v1__;
  if (!state || state.token !== args.documentToken) throw new Error('stale_document');
  const el = state.refs.get(args.ref)?.deref();
  if (!el?.isConnected) throw new Error('stale_ref');
  if (el.tagName !== 'SELECT') throw new Error('ref_is_not_select');
  if (el.disabled) throw new Error('element_unavailable');
  const wanted = String(args.value);
  const option = [...el.options].find(o => o.label.trim() === wanted || o.value === wanted) ||
    [...el.options].find(o => o.label.trim().toLowerCase() === wanted.trim().toLowerCase());
  if (!option) {
    const options = [...el.options].slice(0, 50).map(o => o.label.trim().slice(0, 80));
    throw new Error('option_not_found: ' + JSON.stringify(options).slice(0, 2000));
  }
  if (option.disabled) throw new Error('option_disabled');
  el.value = option.value;
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return {selected: option.label.trim().slice(0, 120)};
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

// Render only in the leased top document. The closed shadow tree keeps its copy out of page reads.
export function renderTabOverlay({active, label, point, remove = false}) {
  const key = '__switchboard_tab_overlay_v1__';
  let state = globalThis[key];
  if (remove) {
    state?.dispose();
    return;
  }
  if (window !== top || !['http:', 'https:'].includes(location.protocol) || !document.documentElement) return;

  if (!state) {
    const host = document.createElement('div');
    host.setAttribute('aria-hidden', 'true');
    host.inert = true;
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;display:block!important;' +
      'z-index:2147483647!important;pointer-events:none!important;contain:strict!important;direction:ltr!important';
    const root = host.attachShadow({mode: 'closed'});
    const css = new CSSStyleSheet();
    css.replaceSync(`
      * { pointer-events: none; box-sizing: border-box; }
      .outline { position: absolute; inset: 0; border: 1px solid rgb(227 118 57 / .88);
        box-shadow: inset 0 0 9px rgb(239 127 51 / .30); }
      .outline.active { border-color: #ff9757; box-shadow: inset 0 0 13px rgb(255 136 55 / .55); }
      .badge { position: absolute; top: 0; left: 50%; transform: translateX(-50%); display: flex;
        align-items: center; justify-content: center; gap: 8px; width: max-content; max-width: 100%;
        min-height: 30px; padding: 5px 13px; border-radius: 0 0 9px 9px;
        background: #a34724; color: #fff; box-shadow: 0 5px 8px rgb(156 63 29 / .27);
        font: 600 12px/1.2 system-ui; text-align: center; }
      .badge::before { content: ""; flex: 0 0 7px; height: 7px; border: 1px solid currentColor;
        border-radius: 2px; transform: rotate(45deg); }
      .active + .badge { background: #ae411a; }
      .active + .badge::before { background: currentColor; }
      svg { position: absolute; width: 21px; height: 25px; overflow: visible;
        filter: drop-shadow(0 1px 2px #29170e); }
    `);
    root.adoptedStyleSheets = [css];
    const outline = document.createElement('div');
    outline.className = 'outline';
    const badge = document.createElement('div');
    badge.className = 'badge';
    const svgNamespace = 'http://www.w3.org/2000/svg';
    const cursor = document.createElementNS(svgNamespace, 'svg');
    cursor.setAttribute('viewBox', '0 0 21 25');
    const arrow = document.createElementNS(svgNamespace, 'path');
    arrow.setAttribute('d', 'M0 0L18 12L10 14L7 23Z');
    arrow.setAttribute('fill', '#ff9f5a');
    arrow.setAttribute('stroke', '#fff6ef');
    arrow.setAttribute('stroke-width', '1.5');
    arrow.setAttribute('stroke-linejoin', 'round');
    cursor.append(arrow);
    root.append(outline, badge, cursor);
    const checkExpiry = () => { if (Date.now() >= state.expires) state.dispose(); };
    const dispose = () => {
      clearTimeout(state.expiryTimer);
      clearTimeout(state.pointerTimer);
      document.removeEventListener('visibilitychange', checkExpiry);
      window.removeEventListener('pagehide', dispose);
      host.remove();
      delete globalThis[key];
    };
    state = globalThis[key] = {host, outline, badge, cursor, dispose};
    document.addEventListener('visibilitychange', checkExpiry);
    window.addEventListener('pagehide', dispose, {once: true});
  }
  if (!state.host.isConnected) document.documentElement.append(state.host);
  state.outline.classList.toggle('active', active);
  if (state.badge.textContent !== label) state.badge.textContent = label;
  clearTimeout(state.expiryTimer);
  state.expires = Date.now() + 18000;
  state.expiryTimer = setTimeout(state.dispose, 18000);

  // CDP sends CSS pixels in the main viewport. Render only a fresh point in that same document.
  clearTimeout(state.pointerTimer);
  state.cursor.style.display = 'none';
  if (point && point.expires > Date.now() && globalThis.__switchboard_page_v1__?.token === point.documentToken &&
      point.x >= 0 && point.y >= 0 && point.x < innerWidth && point.y < innerHeight &&
      (!visualViewport || (visualViewport.scale === 1 && visualViewport.offsetLeft === 0 && visualViewport.offsetTop === 0))) {
    const rect = state.host.getBoundingClientRect();
    if (rect.left !== 0 || rect.top !== 0 || rect.width !== document.documentElement.clientWidth ||
        rect.height !== document.documentElement.clientHeight) return;
    state.cursor.style.left = point.x + 'px';
    state.cursor.style.top = point.y + 'px';
    state.cursor.style.display = 'block';
    state.pointerTimer = setTimeout(() => { state.cursor.style.display = 'none'; }, point.expires - Date.now());
  }
}
