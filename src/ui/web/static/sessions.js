// sessions.js -- the Sessions tab: every stored conversation, to read,
// rename, resume or delete (server side: ui/web/session-routes.lisp).
//
//   List      conversations, newest activity first; the filter matches
//             names, first and last messages, and IDs.  Tick several to
//             delete them together; sessions with no conversation at all
//             (most are: subagents, quick starts) are counted, not listed,
//             and one button clears them.
//   Preview   the selected session's conversation, read from its log.
//   Keys      ↑↓ select · Enter resume · F2 rename · Delete delete (press
//             twice) · / filter.  A session in use cannot be deleted.

import { state, on, el, api, registerView, storage, store } from './core.js';
import { sanitize } from './render.js';
import { showView, activeView } from './views.js';
import { ago, resume } from './session.js';

const toast = (text, color) => window.CLAgent?.toast(text, color);

const view = {
  node: null,
  sessions: [],
  empty: 0,
  current: null,
  selected: storage('sessions-selected', null),
  ticked: new Set(),
  query: '',
  renaming: null,         // id being renamed
  confirming: null,       // a key ('one:ID', 'ticked', 'empty') awaiting a second press
  confirmTimer: null,
  transcripts: new Map(), // id -> {events, data}
  loading: false,
  stale: true,
};

const $ = sel => view.node?.querySelector(sel);
const title = s => s.name || s.title || s.id;

// ---------- data ----------

async function load() {
  if (view.loading) return;
  view.loading = true;
  try {
    const data = await api('/api/sessions');
    view.sessions = data.sessions;
    view.empty = data.empty;
    view.current = data.current;
    view.stale = false;
    for (const id of view.ticked) if (!view.sessions.some(s => s.id === id)) view.ticked.delete(id);
    if (!view.sessions.some(s => s.id === view.selected)) view.selected = view.sessions[0]?.id ?? null;
  } catch (err) {
    toast(err.message, 'red');
  } finally {
    view.loading = false;
  }
  renderList();
  renderPreview();
}

function shown() {
  const q = view.query.trim().toLowerCase();
  if (!q) return view.sessions;
  return view.sessions.filter(s => [s.name, s.title, s.last, s.id].some(t => t && t.toLowerCase().includes(q)));
}

const find = id => view.sessions.find(s => s.id === id);

// ---------- actions ----------

function confirmTwice(key, button, label) {
  if (view.confirming === key) {
    clearTimeout(view.confirmTimer);
    view.confirming = null;
    return true;
  }
  view.confirming = key;
  clearTimeout(view.confirmTimer);
  view.confirmTimer = setTimeout(() => { view.confirming = null; renderList(); renderPreview(); }, 4000);
  if (button) button.textContent = label;
  renderList();
  renderPreview();
  return false;
}

async function remove(body, what) {
  try {
    const result = await api('/api/sessions/delete', { method: 'POST', body });
    for (const id of result.deleted) { view.ticked.delete(id); view.transcripts.delete(id); }
    if (result.deleted.length) toast(`Deleted ${result.deleted.length} ${what}${result.deleted.length === 1 ? '' : 's'}.`, 'green');
    if (result.skipped.length) toast(result.skipped.map(s => s.reason).join(' '), 'orange');
  } catch (err) { toast(err.message, 'red'); }
  await load();
}

function deleteOne(s, button) {
  if (s.in_use) { toast('This session is in use; resume another before deleting it.', 'orange'); return; }
  if (confirmTwice(`one:${s.id}`, button, 'Really delete?')) {
    const index = shown().findIndex(x => x.id === s.id);
    const next = shown()[index + 1] || shown()[index - 1];
    if (view.selected === s.id) view.selected = next?.id ?? null;
    remove({ ids: [s.id] }, 'session');
  }
}

function deleteTicked(button) {
  const ids = [...view.ticked].filter(id => !find(id)?.in_use);
  if (!ids.length) return;
  if (confirmTwice('ticked', button, `Really delete ${ids.length}?`)) remove({ ids }, 'session');
}

function deleteEmpty(button) {
  if (confirmTwice('empty', button, `Really delete ${view.empty}?`)) remove({ empty: true }, 'empty session');
}

async function rename(s, name) {
  view.renaming = null;
  if ((name || '') === (s.name || '')) { renderList(); renderPreview(); return; }
  try {
    const result = await api('/api/sessions/rename', { method: 'POST', body: { id: s.id, name } });
    s.name = result.name;
    toast(result.name ? `Renamed to "${result.name}".` : 'Name cleared.', 'green');
  } catch (err) { toast(err.message, 'red'); }
  renderList();
  renderPreview();
}

function startRename(s) {
  view.renaming = s.id;
  renderList();
  renderPreview();
  const input = $(`.session-row[data-id="${CSS.escape(s.id)}"] .session-rename`);
  input?.focus();
  input?.select();
}

async function resumeSession(s, button) {
  if (await resume(s, button)) showView('listener');
}

function select(id, { scroll = false } = {}) {
  if (!id || id === view.selected) return;
  view.selected = id;
  store('sessions-selected', id);
  renderList();
  renderPreview();
  if (scroll) $(`.session-row[data-id="${CSS.escape(id)}"]`)?.scrollIntoView({ block: 'nearest' });
}

// ---------- rendering ----------

function chips(s) {
  return [
    s.id === view.current ? el('span', { class: 'chip fill-green', 'data-doc': 'The conversation in the Listener' }, 'current')
      : s.in_use ? el('span', { class: 'chip fill-yellow', 'data-doc': 'Used by a session in this cl-agent' }, 'in use') : '',
    s.parent ? el('span', { class: 'chip fill-paper', 'data-doc': `Branched from ${s.parent}` }, 'branch') : '',
    s.error ? el('span', { class: 'chip fill-red', 'data-doc': `Its log could not be read: ${s.error}` }, 'unreadable') : '',
  ];
}

function nameField(s) {
  const input = el('input', {
    class: 'field session-rename', type: 'text', value: s.name || '', maxlength: 160,
    placeholder: s.title || 'Name this session', spellcheck: 'false',
    'data-doc': 'Enter: save · Esc: cancel · empty: clear the name',
  });
  input.addEventListener('keydown', e => {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); rename(s, input.value.trim()); }
    if (e.key === 'Escape') { e.preventDefault(); view.renaming = null; renderList(); renderPreview(); view.node.querySelector('.session-list')?.focus(); }
  });
  input.addEventListener('blur', () => { if (view.renaming === s.id) rename(s, input.value.trim()); });
  input.addEventListener('click', e => e.stopPropagation());
  return input;
}

function row(s) {
  const box = el('input', {
    type: 'checkbox', checked: view.ticked.has(s.id), disabled: s.in_use,
    'data-doc': s.in_use ? 'In use: cannot be deleted' : 'Tick to delete several at once',
    onclick: e => e.stopPropagation(),
    onchange: e => { if (e.target.checked) view.ticked.add(s.id); else view.ticked.delete(s.id); renderToolbar(); },
  });
  return el('div', {
    class: `session-row ${s.id === view.selected ? 'selected' : ''}`, 'data-id': s.id,
    'data-doc': 'Click: preview · Double-click: resume', onclick: () => select(s.id),
    ondblclick: () => { if (!s.error && s.id !== view.current) resumeSession(s); },
  },
    box,
    el('div', { class: 'session-text' },
      view.renaming === s.id ? nameField(s)
        : el('div', { class: 'session-name' }, el('span', { class: s.name ? 'named' : '' }, title(s)), chips(s)),
      el('div', { class: 'session-meta' },
        s.error ? `${s.events} events · ${ago(s.last_active)} · ${s.error}`
          : `${s.user_messages} message${s.user_messages === 1 ? '' : 's'} from you · ${ago(s.last_active)}`,
        s.name && s.title ? el('span', { class: 'faint' }, ` · ${s.title}`) : '')));
}

function renderToolbar() {
  const bar = $('.sessions-toolbar');
  if (!bar) return;
  const ticked = [...view.ticked].filter(id => find(id) && !find(id).in_use).length;
  const deleteTickedButton = ticked ? el('button', {
    class: 'btn btn-small btn-danger', type: 'button', 'data-doc': 'Permanently delete the ticked sessions',
    onclick: e => deleteTicked(e.currentTarget),
  }, view.confirming === 'ticked' ? `Really delete ${ticked}?` : `Delete ${ticked} ticked`) : '';
  const emptyButton = view.empty ? el('button', {
    class: 'btn btn-small', type: 'button',
    'data-doc': 'Sessions with no message from you (subagents, quick starts): delete them all',
    onclick: e => deleteEmpty(e.currentTarget),
  }, view.confirming === 'empty' ? `Really delete ${view.empty}?` : `Clear ${view.empty} empty`) : '';
  bar.querySelector('.sessions-count').textContent =
    view.stale && !view.sessions.length ? 'Reading sessions…'
      : `${shown().length}${view.query ? ` of ${view.sessions.length}` : ''} conversation${view.sessions.length === 1 ? '' : 's'}`;
  bar.querySelector('.sessions-actions').replaceChildren(deleteTickedButton, emptyButton);
}

function renderList() {
  const list = $('.session-list');
  if (!list) return;
  renderToolbar();
  const rows = shown();
  list.replaceChildren(...(rows.length ? rows.map(row)
    : [el('div', { class: 'empty' }, view.loading || view.stale ? 'Reading sessions…'
        : view.query ? 'No session matches.' : 'No stored conversations yet.')]));
}

function entry(item) {
  switch (item.role) {
    case 'user':
      return el('article', { class: `entry user ${item.text.startsWith('/') ? 'command' : ''}` },
        el('div', { class: 'label' }, '(C)'), el('div', { class: 'body' }, item.text));
    case 'assistant': {
      const body = el('div', { class: 'body' });
      if (item.html) { body.classList.add('markdown'); body.innerHTML = sanitize(item.html); }
      else { body.style.whiteSpace = 'pre-wrap'; body.textContent = item.text; }
      return el('article', { class: 'entry assistant' }, el('div', { class: 'label' }, '(D)'), body);
    }
    case 'tool-call':
      return el('div', { class: 'session-tool' }, el('span', { class: 'tool-glyph' }, '▸ '), item.text);
    case 'tool':
      return el('details', { class: 'session-tool-output' },
        el('summary', {}, `${item.name} output`), el('pre', {}, item.text));
    default:
      return el('article', { class: 'entry system' }, el('div', { class: 'label' }, ';;;'), el('div', { class: 'body' }, item.text));
  }
}

async function loadTranscript(s) {
  const cached = view.transcripts.get(s.id);
  if (cached && cached.events === s.events) return cached.data;
  const data = await api('/api/sessions/transcript', { params: { id: s.id } });
  view.transcripts.set(s.id, { events: s.events, data });
  return data;
}

const busy = () => !!(state.thinking || state.planning);

function head(s) {
  return el('div', { class: 'session-head' },
    el('div', { class: 'session-head-title' },
      view.renaming === s.id ? '' : el('span', { class: 'session-head-name' }, title(s)), chips(s)),
    el('div', { class: 'session-head-meta' },
      `${s.id} · started ${ago(s.created_at)} · active ${ago(s.last_active)} · ${s.messages} messages · ${s.events} events`),
    el('div', { class: 'session-head-actions' },
      s.id === view.current || s.error ? '' : el('button', {
        class: 'btn btn-small btn-primary', type: 'button', disabled: busy(),
        'data-doc': busy() ? 'The agent is busy' : 'Continue this conversation in the Listener (Enter)',
        onclick: e => resumeSession(s, e.currentTarget),
      }, 'Resume'),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Name this session (F2)', onclick: () => startRename(s) }, 'Rename'),
      el('button', {
        class: 'btn btn-small btn-danger', type: 'button', disabled: s.in_use,
        'data-doc': s.in_use ? 'In use: resume another session first' : 'Permanently delete this session (Delete, twice)',
        onclick: e => deleteOne(s, e.currentTarget),
      }, view.confirming === `one:${s.id}` ? 'Really delete?' : 'Delete')));
}

/** Show the selected session; its transcript is only rebuilt when the
selection (or the session's log) changed, so scrolling survives. */
async function renderPreview() {
  const pane = $('.session-preview');
  if (!pane) return;
  const s = find(view.selected);
  if (!s) {
    delete pane.dataset.shows;
    pane.replaceChildren(el('div', { class: 'session-preview-empty' }, view.sessions.length ? 'Select a session.' : ''));
    return;
  }
  const key = `${s.id}@${s.events}`;
  if (pane.dataset.shows === key) {
    pane.querySelector('.session-head')?.replaceWith(head(s));
    return;
  }
  pane.dataset.shows = key;
  const body = el('div', { class: 'session-transcript' }, el('div', { class: 'empty' }, 'Reading the conversation…'));
  pane.replaceChildren(head(s), body);
  try {
    const data = await loadTranscript(s);
    if (pane.dataset.shows !== key) return;
    body.replaceChildren(
      data.total > data.entries.length
        ? el('div', { class: 'faint session-clipped' }, `Showing the last ${data.entries.length} of ${data.total} entries.`) : '',
      ...data.entries.map(entry));
  } catch (err) {
    if (pane.dataset.shows === key) { delete pane.dataset.shows; body.replaceChildren(el('div', { class: 'empty' }, err.message)); }
  }
}

// ---------- the view ----------

function onKey(e) {
  if (e.target.tagName === 'INPUT') return;
  const rows = shown();
  const index = rows.findIndex(s => s.id === view.selected);
  const s = rows[index];
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const next = rows[Math.max(0, Math.min(rows.length - 1, index + (e.key === 'ArrowDown' ? 1 : -1)))];
    if (next) select(next.id, { scroll: true });
  } else if (e.key === 'Enter' && s && s.id !== view.current && !s.error) {
    e.preventDefault(); resumeSession(s);
  } else if (e.key === 'F2' && s) {
    e.preventDefault(); startRename(s);
  } else if ((e.key === 'Delete' || e.key === 'Backspace') && s) {
    e.preventDefault(); deleteOne(s);
  } else if (e.key === '/') {
    e.preventDefault(); $('.sessions-filter')?.focus();
  }
}

function mount(node) {
  view.node = node;
  const filter = el('input', {
    class: 'field sessions-filter', type: 'search', placeholder: 'Filter by name, message or ID…', spellcheck: 'false',
  });
  filter.addEventListener('input', () => { view.query = filter.value; renderList(); });
  filter.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown' || e.key === 'Enter') { e.preventDefault(); node.querySelector('.session-list').focus(); }
    if (e.key === 'Escape') { filter.value = ''; view.query = ''; renderList(); }
  });
  const list = el('div', { class: 'session-list', tabindex: '0', role: 'listbox', 'aria-label': 'Sessions' });
  list.addEventListener('keydown', onKey);
  node.append(
    el('div', { class: 'subpane-title sessions-toolbar' },
      el('span', { class: 'subpane-name' }, 'Sessions'),
      el('span', { class: 'subpane-info sessions-count' }, ''),
      el('span', { class: 'spacer' }),
      el('span', { class: 'sessions-actions' }),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Read the sessions again', onclick: load }, 'Refresh')),
    el('div', { class: 'sessions-split' },
      el('div', { class: 'subpane sessions-list-pane' }, el('div', { class: 'sessions-filter-row' }, filter), list),
      el('div', { class: 'subpane session-preview' })));
  renderList();
  load();
}

registerView({
  id: 'sessions', title: 'Sessions', color: 'green', order: 20,
  doc: 'Every stored conversation: read, rename, resume or delete it (Alt-S)',
  mount,
  show: () => { if (view.stale) load(); setTimeout(() => $('.session-list')?.focus(), 0); },
});

// Another page renamed or deleted one, or the Listener's conversation changed.
const refresh = () => { view.stale = true; if (view.node && activeView() === 'sessions') load(); };
on('sessions', refresh);
on('reset', refresh);
on('message', ev => { if (ev.message?.role === 'user') view.stale = true; });
let wasBusy = false;
on('status', () => {
  if (busy() === wasBusy) return;
  wasBusy = busy();
  if (view.node) renderPreview();
});
