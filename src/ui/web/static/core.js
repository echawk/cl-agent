// core.js -- the client's core: state store, event bus, server transport,
// plugin registries and small DOM/format helpers.  It renders nothing.
//
// Everything exported here is also reachable as window.CLAgent (main.js
// assembles it), which is the API patches/*.js plugins use.  See
// EXTENDING.md for the guided tour.
//
// Transport: GET /api/state returns a snapshot carrying `seq`, the number
// of the newest server event it reflects; GET /api/events?since=SEQ then
// streams every later event (Server-Sent Events).  apply() folds each event
// into `state` with a reducer and re-emits it, so UI code subscribes with
// on('message' | 'delta' | 'pending' | 'activity' | 'status' | 'subagents'
// | 'asset' | 'ui' | 'change' | 'state' | 'connection' | 'lisp-entry'
// | 'lisp-output' | 'lisp-scratch' | 'lisp-clear' | 'model' | 'tools', fn).

export const boot = window.CL_AGENT_BOOT || { safe: false, assets: '/assets' };

export const state = {
  seq: 0,
  instance: null,
  connected: false,
  messages: [],     // {id, role, text, html, turn, time, inline}
  pending: '',      // the reply streaming in right now
  thinking: false,
  planning: false,
  queued: [],
  turn: 0,
  stats: null,
  activity: [],     // {id, kind, label, text, turn, time, ref, tool}
  subagents: [],
  session: {},
  ui: {},
};

// ---------- events ----------

const handlers = new Map();

export function on(type, fn) {
  if (!handlers.has(type)) handlers.set(type, new Set());
  handlers.get(type).add(fn);
  return () => off(type, fn);
}

export function off(type, fn) {
  handlers.get(type)?.delete(fn);
}

export function emit(type, detail) {
  for (const fn of [...(handlers.get(type) || [])]) {
    try { fn(detail, state); } catch (err) { console.error(`[cl-agent] "${type}" handler failed`, err); }
  }
}

// ---------- live sessions ----------
//
// The page shows one live session at a time (live.js lists them down the
// left edge).  Every request names it (X-CL-Agent-Session; ?session= for
// the event stream); with none named, the server answers for its first.
// Remembered per browser tab, so two tabs can follow two sessions.

export const live = { id: (() => { try { return sessionStorage.getItem('cl-agent.live'); } catch (err) { return null; } })() };

/** Show live session ID: its transcript, activity and events replace these. */
export function switchLive(id) {
  if (id === live.id) return;
  live.id = id;
  try { if (id) sessionStorage.setItem('cl-agent.live', id); else sessionStorage.removeItem('cl-agent.live'); } catch (err) { /* private mode */ }
  Object.assign(state, { seq: 0, instance: null, messages: [], pending: '', thinking: false, planning: false,
                         queued: [], turn: 0, activity: [], subagents: [], stats: null });
  emit('live-switch', id);
  loadState();
}

// ---------- server API ----------

export async function api(path, { method = 'GET', body, params } = {}) {
  const url = new URL(path, location.origin);
  for (const [key, value] of Object.entries(params || {})) url.searchParams.set(key, value);
  const init = { method, headers: {}, cache: 'no-store' };
  if (live.id) init.headers['X-CL-Agent-Session'] = live.id;
  // Mutating requests must carry this header (the server's CSRF guard).
  if (method !== 'GET') init.headers['X-CL-Agent'] = '1';
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(url, init);
  const type = response.headers.get('Content-Type') || '';
  const data = type.includes('json') ? await response.json() : await response.text();
  if (!response.ok) throw new Error((data && data.error) || `${response.status} ${response.statusText}`);
  return data;
}

export const send = text => api('/api/send', { method: 'POST', body: { text } });
export const interrupt = () => api('/api/interrupt', { method: 'POST' });

// ---------- reducers: how each server event changes `state` ----------

const reducers = {
  message(ev) {
    state.messages.push(ev.message);
    if (ev.message.role === 'user') state.turn = Math.max(state.turn, ev.message.turn);
  },
  delta(ev) { state.pending += ev.chunk; },
  pending(ev) { state.pending = ev.text; },
  activity(ev) {
    state.activity.push(ev.entry);
    if (state.activity.length > 4000) state.activity.splice(0, state.activity.length - 3000);
  },
  status(ev) { Object.assign(state, ev.status); },
  subagents(ev) { state.subagents = ev.items; },
};

/** Fold a custom server event (published with WEB-UI-BROADCAST) into state. */
export function registerReducer(type, fn) { reducers[type] = fn; }

function apply(ev) {
  if (ev.seq <= state.seq) return;                 // already reflected
  if (ev.seq !== state.seq + 1) { loadState(); return; }   // a gap: resync
  state.seq = ev.seq;
  reducers[ev.type]?.(ev);
  emit(ev.type, ev);
  if (ev.type === 'ui') runUICommand(ev.command, ev.args || {});
  emit('change', ev);
}

// ---------- transport ----------

let source = null;
let retryTimer = null;

function setConnected(value) {
  if (state.connected !== value) {
    state.connected = value;
    emit('connection', value);
  }
}

export async function loadState() {
  clearTimeout(retryTimer);
  try {
    const snapshot = await api('/api/state', { params: boot.safe ? { safe: 1 } : {} });
    Object.assign(state, snapshot);
    setConnected(true);
    emit('state', state);
    emit('change', null);
    openStream();
  } catch (err) {
    setConnected(false);
    retryTimer = setTimeout(loadState, 2000);
  }
}

function openStream() {
  source?.close();
  source = new EventSource(`/api/events?since=${state.seq}${live.id ? `&session=${encodeURIComponent(live.id)}` : ''}`);
  source.onmessage = message => {
    try { apply(JSON.parse(message.data)); } catch (err) { console.error('[cl-agent] bad event', err); }
  };
  source.addEventListener('hello', message => {
    const hello = JSON.parse(message.data);
    setConnected(true);
    // A restarted server numbers events from zero again.
    if (hello.instance !== state.instance || hello.seq < state.seq) loadState();
  });
  source.addEventListener('resync', () => loadState());
  source.addEventListener('bye', () => {
    source.close();
    setConnected(false);
    retryTimer = setTimeout(loadState, 2000);
  });
  source.onerror = () => setConnected(false);   // EventSource retries by itself
}

// ---------- plugin registries ----------

/** Side panels: {id, title, color, order, doc, badge(state), render(el, state, ev)}. */
export const panels = new Map();
export function registerPanel(panel) {
  panels.set(panel.id, { order: 50, color: 'blue', ...panel });
  emit('panels', panels);
}

/** Main-pane views (tabs beside the Listener): {id, title, color, order, doc,
 *  badge(state), mount(el) (once, when first shown), show(el)?, hide(el)?}. */
export const views = new Map();
export function registerView(view) {
  views.set(view.id, { order: 50, color: 'blue', ...view });
  emit('views', views);
}

/** Render a transcript role yourself: fn(message, element) fills element. */
export const messageRenderers = new Map();
export function registerRenderer(role, fn) {
  messageRenderers.set(role, fn);
  emit('rerender');
}

/** Adjust every rendered transcript entry: fn(element, message). */
export const messageDecorators = [];
export function registerMessageDecorator(fn) {
  messageDecorators.push(fn);
  emit('rerender');
}

/** Slash commands handled in the browser: run(argString) -> maybe a Promise. */
export const clientCommands = new Map();
/** Functions called with TURNSECTION (turn -> its <section>) on every full
render of the listener, to put more in the transcript: forms.js's Lisp
evaluations.  (Here, not in render.js, so modules can add to it while the
module graph is still loading.) */
export const turnExtras = [];

export function registerCommand(name, run, doc = '') {
  clientCommands.set(name.replace(/^\//, ''), { run, doc });
}

/** Commands the server can send (web-ui-command / WEB-UI-COMMAND): fn(args). */
export const uiCommands = new Map();
export function registerUICommand(name, fn) { uiCommands.set(name, fn); }
export function runUICommand(name, args) {
  const command = uiCommands.get(name);
  if (command) {
    try { command(args); } catch (err) { console.error(`[cl-agent] ui command ${name} failed`, err); }
  }
  emit(`ui:${name}`, args);
}

/** Client-side completion: fn(text, cursor) -> {start, end, candidates} or null. */
export const completers = [];
export function registerCompleter(fn) { completers.push(fn); }

// ---------- theme ----------

export function theme() { return document.documentElement.dataset.theme || 'light'; }

/** The themes this page has: light and dark, and any a stylesheet adds --
a patch styling html[data-theme="NAME"] (patches/NAME-theme.css, say) makes
NAME one, with no other file to change. */
export function themes() {
  const names = new Set(['light', 'dark']);
  const scan = rules => {
    for (const rule of rules || []) {
      for (const [, name] of (rule.selectorText || '').matchAll(/data-theme="([\w-]+)"/g)) names.add(name);
      if (rule.cssRules) scan(rule.cssRules);
    }
  };
  for (const sheet of document.styleSheets) {
    try { scan(sheet.cssRules); } catch (err) { /* another origin's: no rules to read */ }
  }
  return [...names];
}

export function setTheme(name) {
  const all = themes();
  const next = name === 'toggle' ? all[(all.indexOf(theme()) + 1) % all.length] : name;
  if (!all.includes(next)) return;
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem('cl-agent.theme', next); } catch (err) { /* private mode */ }
  emit('theme', next);
}

// ---------- helpers ----------

/** el('div', {class: 'x', onclick: fn, dataset: {...}}, child, 'text', ...) */
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (key === 'style' && typeof value === 'object') {
      // Custom properties (--tab-color) only take effect through setProperty.
      for (const [name, v] of Object.entries(value)) {
        if (name.startsWith('--')) node.style.setProperty(name, v); else node.style[name] = v;
      }
    }
    else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value);
    else if (key === 'html') node.innerHTML = value;
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export const esc = text => String(text ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export const now = () => Date.now() / 1000;

export function fmtDuration(seconds) {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`;
  return `${Math.floor(s / 3600)}h${String(Math.floor(s / 60) % 60).padStart(2, '0')}m`;
}

export function fmtCount(n) {
  if (!n) return '0';
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e4) return `${Math.round(n / 1e3)}k`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`;
  return String(n);
}

export function fmtClock(unix) {
  return new Date(unix * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export async function copyText(text, button) {
  try {
    await navigator.clipboard.writeText(text);
    if (button) {
      const old = button.textContent;
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = old; }, 1100);
    }
  } catch (err) {
    if (button) button.textContent = 'Copy failed';
  }
}

/** Run fn at most once per animation frame, however often it is scheduled. */
export function frameThrottle(fn) {
  let queued = false;
  let lastArg;
  return arg => {
    lastArg = arg;
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; fn(lastArg); });
  };
}

export function storage(key, fallback) {
  try {
    const value = localStorage.getItem(`cl-agent.${key}`);
    return value === null ? fallback : JSON.parse(value);
  } catch (err) { return fallback; }
}

export function store(key, value) {
  try { localStorage.setItem(`cl-agent.${key}`, JSON.stringify(value)); } catch (err) { /* ignore */ }
}
