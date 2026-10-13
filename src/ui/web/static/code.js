// code.js -- the Code tab: scratch buffers in any language, shared with the
// agent (server side: scratch.lisp, ui/web/scratch-routes.lisp).
//
//   Buffers   each is a real file, scratch/NAME.EXT in the config directory;
//             New asks for a name and a language (every language Lem
//             highlights, plus plain text)
//   Editor    the Lisp tab's editor in its generic mode: Lem highlights the
//             text with its own mode for the language; Emacs keys, M-/,
//             Tab/Shift-Tab indent.  Saved as you type; C-x C-s saves now
//   Language  Tab (or C-M-i) completes from the language server configured
//   server    for the extension, as Lem's lsp-mode does (its trigger
//             characters, "." "->" ..., open the menu by themselves); without
//             one, from the buffer's own words.  Check (C-c C-c) lists its
//             diagnostics (click one to go there); C-c C-d d shows its hover
//             text for the symbol at the cursor
//   Agent     Ask the agent puts a request in the composer; the agent reads
//             and edits buffers with scratch-buffers / scratch-buffer-write,
//             and its edits appear here at once (a clash with unsaved typing
//             asks which to keep)

import { on, el, api, registerView, storage, store } from './core.js';
import { createLispEditor } from './lisp-editor.js';
import { insert as insertInComposer } from './composer.js';

const client = `code-${Math.random().toString(36).slice(2)}`;
const toast = (text, color) => window.CLAgent?.toast(text, color);

const INDENT = { Python: 4, C: 4, Java: 4, Rust: 4, Go: 4, Haskell: 4, Swift: 4, Kotlin: 4, Scala: 2, Perl: 4, Lua: 2 };

const view = {
  node: null,
  buffers: [],
  languages: [],
  lem: null,
  selected: storage('code-selected', null),
  buffer: null,           // {name, text, version, language, path, servers}
  editor: null,
  saved: '',
  dirty: false,
  saveTimer: 0,
  diagnostics: null,      // null: not checked; [] none
  triggers: [],           // the language server's completion trigger characters
  stale: true,
  listNumber: 0,          // the latest list request: older answers are stale
};

const $ = sel => view.node?.querySelector(sel);

// ---------- data ----------

async function loadList() {
  const number = ++view.listNumber;
  try {
    const data = await api('/api/scratch');
    // The first request starts Lem and can be slow: never let it undo a
    // newer one (a buffer made meanwhile would vanish).
    if (number !== view.listNumber) return;
    view.buffers = data.buffers;
    view.languages = data.languages;
    view.lem = data.lem;
    view.stale = false;
  } catch (err) { toast(err.message, 'red'); }
  if (!view.buffers.some(b => b.name === view.selected)) view.selected = view.buffers[0]?.name ?? null;
  renderList();
  if (view.selected && view.buffer?.name !== view.selected) open(view.selected);
  if (!view.selected) { view.buffer = null; renderEditor(); }
}

async function open(name) {
  if (view.dirty) await save(true);
  view.selected = name;
  store('code-selected', name);
  renderList();
  try {
    view.buffer = await api('/api/scratch/buffer', { params: { name } });
  } catch (err) { toast(err.message, 'red'); return; }
  view.saved = view.buffer.text;
  view.dirty = false;
  view.diagnostics = null;
  view.triggers = [];
  renderEditor();
  // Start its language server now, as Lem does on opening a file: the
  // first Tab is quicker and "." "->" open completion from the start.
  if (view.buffer.servers?.length) {
    api('/api/scratch/lsp-start', { method: 'POST', body: { name } })
      .then(({ triggers }) => { if (view.buffer?.name === name) view.triggers = triggers; })
      .catch(err => message(err.message));
  }
}

async function save(now = false) {
  clearTimeout(view.saveTimer);
  if (!view.buffer) return;
  if (!now) { view.saveTimer = setTimeout(() => save(true), 700); return; }
  const { name } = view.buffer;
  const text = view.editor.value;
  if (text === view.saved) { view.dirty = false; renderChrome(); return; }
  try {
    const { version } = await api('/api/scratch/save', { method: 'POST', body: { name, text, base: view.buffer.version, client } });
    if (view.buffer?.name !== name) return;
    view.buffer.version = version;
    view.saved = text;
    view.dirty = view.editor.value !== text;
    if (view.dirty) save();
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const current = await api('/api/scratch/buffer', { params: { name } });
      showConflict(current.text, current.version, 'someone');
    } else message(`Not saved: ${err.message}`);
  }
  renderChrome();
}

// The problems listed describe text that has since changed.
function diagnosticsStale() {
  $('.code-diagnostics')?.classList.toggle('stale', view.diagnostics !== null);
}

function setText(text, version) {
  view.buffer.text = text;
  view.buffer.version = version;
  view.saved = text;
  view.dirty = false;
  view.editor.value = text;
  diagnosticsStale();
  renderChrome();
}

function showConflict(text, version, by) {
  const box = $('.code-conflict');
  box.hidden = false;
  box.replaceChildren(
    el('span', {}, `${by === 'agent' ? 'The agent' : 'Someone'} changed this buffer while you were editing.`),
    el('button', { class: 'btn btn-small', type: 'button', onclick: () => { box.hidden = true; setText(text, version); } }, 'Use theirs'),
    el('button', {
      class: 'btn btn-small', type: 'button',
      onclick: () => { box.hidden = true; view.buffer.version = version; save(true); },
    }, 'Keep mine'));
}

async function create(name, language) {
  try {
    const buffer = await api('/api/scratch/create', { method: 'POST', body: { name, language } });
    $('.code-new').hidden = true;
    view.selected = buffer.name;
    await loadList();
    if (view.buffer?.name !== buffer.name) await open(buffer.name);
    view.editor?.focus();
  } catch (err) { message(err.message); }
}

async function remove() {
  const { name } = view.buffer || {};
  if (!name) return;
  const button = $('.code-delete');
  if (button.dataset.confirm !== name) {
    button.dataset.confirm = name;
    button.textContent = 'Really delete?';
    setTimeout(() => { if (button.isConnected) { button.dataset.confirm = ''; button.textContent = 'Delete'; } }, 3000);
    return;
  }
  try {
    await api('/api/scratch/delete', { method: 'POST', body: { name } });
    view.buffer = null;
    view.selected = null;
    await loadList();
    toast(`Deleted ${name} (a copy is kept in scratch/.history)`);
  } catch (err) { message(err.message); }
}

// ---------- the language server ----------

async function check() {
  if (!view.buffer) return;
  await save(true);
  const list = $('.code-diagnostics');
  list.hidden = false;
  list.replaceChildren(el('div', { class: 'faint code-diag-status' }, 'Asking the language server…'));
  try {
    const { diagnostics } = await api('/api/scratch/diagnostics', { method: 'POST', body: { name: view.buffer.name } });
    view.diagnostics = diagnostics;
  } catch (err) {
    view.diagnostics = null;
    list.replaceChildren(el('div', { class: 'code-diag-status' }, err.message));
    return;
  }
  renderDiagnostics();
}

function renderDiagnostics() {
  const list = $('.code-diagnostics');
  if (!list) return;
  list.classList.remove('stale');
  const items = view.diagnostics;
  if (!items) { list.hidden = true; return; }
  list.hidden = false;
  if (!items.length) { list.replaceChildren(el('div', { class: 'code-diag-status ok' }, '✓ No problems reported')); return; }
  list.replaceChildren(
    el('div', { class: 'code-diag-status' }, `${items.length} ${items.length === 1 ? 'problem' : 'problems'}`),
    ...items.map(d => el('button', {
      class: `code-diag sev-${d.severity}`, type: 'button',
      'data-doc': 'Go to this line',
      onclick: () => {
        if (d.line === null) return;
        view.editor.setCursor(view.editor.offsetOf(d.line, d.character || 0));
        view.editor.focus();
      },
    }, el('span', { class: 'code-diag-where' }, d.line === null ? '' : `${d.line + 1}:${(d.character || 0) + 1}`),
       el('span', { class: 'code-diag-sev' }, d.severity),
       el('span', { class: 'code-diag-message' }, d.message),
       el('span', { class: 'faint' }, d.source || d.server || ''))));
}

// Completion saves first: the language server reads the file.
async function complete(text, cursor) {
  if (!view.buffer) return null;
  const { name } = view.buffer;
  clearTimeout(view.saveTimer);
  try {
    const result = await api('/api/scratch/complete', {
      method: 'POST', body: { name, text, cursor, base: view.buffer.version, client },
    });
    if (view.buffer?.name !== name) return null;
    view.buffer.version = result.version;
    view.saved = text;
    view.dirty = view.editor.value !== text;
    view.triggers = result.triggers || [];
    if (result.message) message(result.message);
    renderChrome();
    return result;
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const current = await api('/api/scratch/buffer', { params: { name } });
      showConflict(current.text, current.version, 'someone');
      return null;
    }
    throw err;
  }
}

async function hover() {
  if (!view.buffer) return;
  await save(true);
  const { line, character } = view.editor.positionOf(view.editor.cursor);
  try {
    const { text } = await api('/api/scratch/hover', { method: 'POST', body: { name: view.buffer.name, line, character } });
    message(text || 'The language server has nothing to say here.', 8000);
  } catch (err) { message(err.message); }
}

// ---------- rendering ----------

let messageTimer = 0;
function message(text, ms = 4000) {
  const echo = $('.code-echo');
  if (!echo) return;
  echo.textContent = text;
  clearTimeout(messageTimer);
  if (ms) messageTimer = setTimeout(() => { echo.textContent = ''; renderChrome(); }, ms);
}

function renderList() {
  const list = $('.code-list');
  if (!list) return;
  $('.code-count').textContent = `${view.buffers.length} ${view.buffers.length === 1 ? 'buffer' : 'buffers'}`
    + (view.lem && view.lem.state !== 'running' && view.lem.state !== 'stopped' ? ` · Lem ${view.lem.state}` : '');
  if (!view.buffers.length) {
    list.replaceChildren(el('div', { class: 'empty code-empty' },
      'No scratch buffers yet. ', el('button', { class: 'btn btn-small', type: 'button', onclick: showNew }, 'New buffer'),
      el('p', { class: 'faint' }, 'Write C, Ruby, Python, Rust… with Lem\'s highlighting, the language server\'s diagnostics, and the agent\'s help.')));
    return;
  }
  list.replaceChildren(...view.buffers.map(b => el('div', {
    class: `code-row ${b.name === view.selected ? 'selected' : ''}`, role: 'option',
    'aria-selected': String(b.name === view.selected),
    onclick: () => open(b.name),
  }, el('span', { class: 'code-row-name' }, b.name),
     el('span', { class: 'chip code-lang' }, b.language || b.extension),
     el('span', { class: 'faint code-row-file' }, `.${b.extension}`))));
}

function renderChrome() {
  const state = $('.code-state');
  if (!state || !view.buffer) return;
  state.textContent = view.dirty ? 'EDITED' : 'SAVED';
  state.className = `chip code-state ${view.dirty ? 'fill-orange' : 'fill-green'}`;
}

function renderEditor() {
  const pane = $('.code-editor-pane');
  if (!pane) return;
  if (!view.buffer) {
    view.editor = null;
    pane.replaceChildren(el('div', { class: 'session-preview-empty' }, view.buffers.length ? 'Pick a buffer.' : ''));
    return;
  }
  const b = view.buffer;
  const servers = b.servers?.length ? b.servers.join(', ') : null;
  const host = el('div', { class: 'code-editor-host' });
  pane.replaceChildren(
    el('div', { class: 'session-head code-head' },
      el('div', { class: 'session-head-title' },
        el('span', { class: 'session-head-name' }, b.name),
        el('span', { class: 'chip code-lang' }, b.language || b.extension),
        el('span', { class: 'chip code-state fill-green' }, 'SAVED')),
      el('div', { class: 'session-head-meta', title: b.path, 'data-doc': b.path }, `scratch/${b.name}.${b.extension}`,
        el('span', { class: servers ? 'code-lsp on' : 'code-lsp' },
          servers ? ` · language server: ${servers}` : ` · no language server for .${b.extension}`)),
      el('div', { class: 'session-head-actions' },
        el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Save now (C-x C-s)', onclick: () => save(true) }, 'Save'),
        el('button', {
          class: 'btn btn-small', type: 'button', disabled: !servers,
          'data-doc': servers ? 'Ask the language server for problems (C-c C-c)' : `Configure a language server for .${b.extension} in lsp.sexp`,
          onclick: check,
        }, 'Check'),
        el('button', {
          class: 'btn btn-small btn-primary', type: 'button', 'data-doc': 'Ask the agent about this buffer (or the selected lines)',
          onclick: () => {
            const { start, end, text } = view.editor.selection;
            insertInComposer(text.trim()
              ? `Look at lines ${view.editor.lineOf(start)}–${view.editor.lineOf(end)} of my ${b.language} scratch buffer "${b.name}".`
              : `Help me with my ${b.language} scratch buffer "${b.name}".`);
          },
        }, 'Ask the agent'),
        el('span', { class: 'spacer' }),
        el('button', { class: 'btn btn-small btn-danger code-delete', type: 'button', 'data-doc': 'Delete this buffer (press twice)', onclick: remove }, 'Delete'))),
    el('div', { class: 'scratch-conflict code-conflict', hidden: true }),
    host,
    el('div', { class: 'code-diagnostics', hidden: true }),
    el('div', { class: 'echo-area code-echo' }));
  view.editor = createLispEditor(host, {
    className: 'code-editor',
    value: b.text,
    doc: `${b.language} scratch buffer · Tab complete · C-x C-s save · C-c C-c check · C-c C-d d hover · M-/ expand`,
    highlight: async text => (await api('/api/highlight', { method: 'POST', body: { text, pathname: `x.${b.extension}` } })).runs,
    indentUnit: INDENT[b.language] || 2,
    wordPattern: /[\w$]/,
    complete,
    triggerCharacters: () => view.triggers,
    keymap: {
      'C-x C-s': () => save(true).then(() => message('Saved.')),
      'C-c C-c': check,
      'C-c C-d d': hover,
      'C-c C-d C-d': hover,
    },
    onChange: () => { view.dirty = true; diagnosticsStale(); renderChrome(); save(); },
    onMessage: text => (text ? message(text, 2500) : null),
  });
  renderChrome();
  renderDiagnostics();
}

function showNew() {
  const form = $('.code-new');
  form.hidden = false;
  const select = form.querySelector('select');
  if (!select.options.length) {
    select.append(...view.languages.map(l => el('option', { value: l.name }, `${l.name} (.${l.extension})`)));
    select.value = storage('code-language', 'C');
  }
  form.querySelector('input').focus();
}

function mount(node) {
  view.node = node;
  const name = el('input', { class: 'field', placeholder: 'name, e.g. hello', spellcheck: 'false', 'aria-label': 'Buffer name' });
  const language = el('select', { class: 'field', 'aria-label': 'Language' });
  const submit = () => {
    store('code-language', language.value);
    create(name.value.trim(), language.value);
  };
  name.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); submit(); }
    if (e.key === 'Escape') $('.code-new').hidden = true;
  });
  node.append(
    el('div', { class: 'subpane-title sessions-toolbar code-toolbar' },
      el('span', { class: 'subpane-name' }, 'Code'),
      el('span', { class: 'subpane-info code-count' }, ''),
      el('span', { class: 'spacer' }),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Make a scratch buffer in any language', onclick: showNew }, 'New'),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Read the buffers again', onclick: loadList }, 'Refresh')),
    el('div', { class: 'sessions-split code-split' },
      el('div', { class: 'subpane code-list-pane' },
        el('form', {
          class: 'code-new', hidden: true,
          onsubmit: e => { e.preventDefault(); submit(); },
        }, name, language, el('button', { class: 'btn btn-small btn-primary', type: 'submit' }, 'Create')),
        el('div', { class: 'code-list', role: 'listbox', 'aria-label': 'Scratch buffers' })),
      el('div', { class: 'subpane code-editor-pane' })));
  renderList();
  renderEditor();
  loadList();
}

registerView({
  id: 'code', title: 'Code', color: 'orange', order: 15,
  doc: 'Scratch buffers in any language, highlighted by Lem, checked by the language server, shared with the agent (Alt-C)',
  mount,
  show: () => { if (view.stale) loadList(); setTimeout(() => view.editor?.focus(), 0); },
});

// The agent (or another page) saved, made or deleted a buffer.
on('scratch-buffer', ev => {
  const b = view.buffers.find(x => x.name === ev.name);
  if (b) b.size = ev.text.length;
  if (ev.client === client || !view.buffer || view.buffer.name !== ev.name) return;
  if (view.dirty && view.editor.value !== ev.text) { showConflict(ev.text, ev.version, ev.by); return; }
  setText(ev.text, ev.version);
  if (ev.by === 'agent') message('The agent updated this buffer.');
});
on('scratch-buffers', ev => {
  view.stale = true;
  if (view.node) loadList();
  if (ev.created && ev.by === 'agent') toast(`The agent made the scratch buffer ${ev.created}`);
});
