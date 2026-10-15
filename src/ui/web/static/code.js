// code.js -- the Code tab: the user's files, edited through the hosted Lem,
// and scratch buffers in any language, both shared with the agent (server
// side: lem/files.lisp, ui/web/file-routes.lisp, scratch.lisp,
// ui/web/scratch-routes.lisp).
//
//   Files     a directory as Lem's dired lists it: click (or Enter) to visit a
//             file or go into a directory; rename, delete, new file/folder,
//             and "cd here" to make it the working directory
//   Open      the files open in Lem; a dot marks unsaved changes
//   Scratch   scratch buffers (scratch/NAME.EXT), saved as you type
//   Editor    the Lisp tab's editor in its generic mode.  A file's text is
//             synced into its Lem buffer as you type and highlighted by that
//             buffer's own mode; nothing reaches the disk until C-x C-s,
//             which is Lem's save-buffer.  Tab completes from the language
//             server (its trigger characters open the menu by themselves),
//             C-c C-c checks, C-c C-d d shows hover text, M-/ expands
//   Minibuffer  C-x C-f find-file and C-x d dired (Lem's file-name
//             completion on Tab), C-x b switch buffer, M-x cd; C-x k closes,
//             C-x C-s saves, C-g cancels -- as in Lem and Emacs
//   Lem view  by default the editor *is* Lem, in an iframe: Lem's own web
//             frontend (lem/display.lisp) showing the hosted Lem -- its
//             windows, mode line, minibuffer, M-x, dired, your init file and
//             keys.  Visiting a file (the Files pane, C-x C-f, the agent's
//             open-in-editor) shows it in Lem's window.  "Simple editor"
//             switches to the lightweight editor below instead
//   Agent     Ask the agent puts a request in the composer; the agent sees
//             open files' unsaved text (editor-files), opens files for you
//             (open-in-editor), and its writes show up here: an unchanged
//             buffer reloads, one with unsaved changes asks which to keep

import { on, el, api, state, registerView, registerUICommand, storage, store, theme } from './core.js';
import { createLispEditor } from './lisp-editor.js';
import { createMenu, commonPrefix, menuStep, menuCancel } from './menu.js';
import { insert as insertInComposer } from './composer.js';
import { showView, activeView } from './views.js';
import { copilotBox, copilotOptions } from './copilot.js';
import { createLemView } from './lem-view.js';

const client = `code-${Math.random().toString(36).slice(2)}`;
const toast = (text, color) => window.CLAgent?.toast(text, color);

const INDENT = { Python: 4, C: 4, 'C++': 4, Java: 4, Rust: 4, Go: 4, Haskell: 4, Swift: 4, Kotlin: 4, Perl: 4 };

const view = {
  node: null,
  pane: storage('code-pane', 'files'),     // files | open | scratch
  // scratch buffers
  buffers: [],
  languages: [],
  lem: null,
  listNumber: 0,          // the latest scratch-list request: older answers are stale
  // files
  dir: storage('code-dir', null),
  listing: null,
  sort: storage('code-sort', 'name'),
  hidden: false,
  openFiles: [],
  rowIndex: 0,
  // the buffer being edited: {kind: 'file'|'scratch', key, ...the server's JSON}
  doc: null,
  current: storage('code-current', null),
  editor: null,
  saved: '',              // scratch: text on disk; file: text as last read or saved
  dirty: false,           // scratch: unsaved; file: unsaved changes (Lem's buffer is modified)
  saveTimer: 0,
  diagnostics: null,
  triggers: [],
  stale: true,
  lemMode: storage('code-lem', true),   // the editor is Lem itself
  lemShown: 0,            // "lem-buffer" events seen: a visit's late answer is stale after one
  lemFile: null,          // what Lem's window shows: {path, name, mode, modified} (path null: not a file)
};

const $ = sel => view.node?.querySelector(sel);
const isFile = () => view.doc?.kind === 'file';
const home = () => state.session?.home || '';
const short = path => (home() && path?.startsWith(home()) ? `~/${path.slice(home().length).replace(/^\//, '')}` : path);

// ---------- scratch buffers ----------

async function loadScratch() {
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
  renderSide();
}

async function createScratch(name, language) {
  try {
    const buffer = await api('/api/scratch/create', { method: 'POST', body: { name, language } });
    $('.code-new').hidden = true;
    await loadScratch();
    await openDoc('scratch', buffer.name);
    view.editor?.focus();
  } catch (err) { message(err.message); }
}

// ---------- files ----------

async function loadDir(dir = view.dir) {
  try {
    const listing = await api('/api/files/list', { params: { dir: dir || '.', sort: view.sort, hidden: view.hidden ? '1' : '0' } });
    view.listing = listing;
    view.dir = listing.directory;
    store('code-dir', view.dir);
    view.rowIndex = Math.min(view.rowIndex, listing.entries.length);
  } catch (err) {
    message(err.message);
    if (dir !== null && view.dir === dir) { view.dir = null; return loadDir(null); }
  }
  renderSide();
  return view.listing;
}

async function loadOpenFiles() {
  try { view.openFiles = (await api('/api/files/buffers')).buffers; } catch (err) { view.openFiles = []; }
  renderSide();
}

async function fileAction(path, body) {
  try { return await api(path, { method: 'POST', body }); } catch (err) { message(err.message); return null; }
}

// ---------- the buffer being edited ----------

// ---------- the Lem view ----------

// Lem's own view, in an iframe (lem-view.js), made when the tab mounts.
let lemView = null;
const ensureLemFrame = () => (lemView ? lemView.ensure() : Promise.resolve(null));
const lemRemeasure = () => lemView?.remeasure();
const focusLem = () => lemView?.focus();

async function lemVisit(path, line) {
  await ensureLemFrame();
  // Lem is shared with the Lisp tab: a visit that lands after you left
  // would cover its scratch buffer.  Showing this tab visits it again.
  if (activeView() !== 'code') return;
  try {
    const shown = view.lemShown;
    const json = await api('/api/lem/visit', { method: 'POST', body: { path, line: line || undefined } });
    // Lem may have moved on meanwhile (C-x b, another visit): it says so.
    if (view.lemShown === shown) noteLemShown(json);
    loadOpenFiles();
    focusLem();
  } catch (err) { message(err.message); }
}

/** Lem's window shows JSON's buffer: it is the current one here. */
function noteLemShown(json) {
  view.lemFile = json;
  if (json.path) {
    // A scratch buffer is a file too: it stays a scratch buffer here.
    const scratch = view.buffers.find(b => b.path === json.path);
    view.doc = scratch ? { ...json, kind: 'scratch', key: scratch.name } : { ...json, kind: 'file', key: json.path };
    view.current = { kind: view.doc.kind, key: view.doc.key };
    store('code-current', view.current);
  }
  renderLemHead();
  renderSide();
}

async function lemRun(command) {
  await ensureLemFrame();
  try { await api('/api/lem/run', { method: 'POST', body: { command } }); focusLem(); } catch (err) { message(err.message); }
}

async function setLemMode(on) {
  if (on === view.lemMode) return;
  // Into Lem, what the simple editor holds goes too: a file's text is in its
  // Lem buffer already (synced as you type) once the last edit is; a
  // scratch buffer is saved, so Lem reads it as it is.  Out of Lem, its
  // current file (view.current, kept by "lem-buffer") opens here.
  if (on && view.doc?.kind === 'scratch' && view.dirty) await saveScratch(true);
  else if (on && isFile()) await syncFile();
  if (on) view.editor = null;
  view.lemMode = on;
  store('code-lem', on);
  renderEditor();
  renderToolbar();
  if (view.current) await openDoc(view.current.kind, view.current.key);
  else if (on) { await ensureLemFrame(); focusLem(); }
}

function renderToolbar() {
  for (const button of view.node?.querySelectorAll('.code-editor-switch button') || []) {
    const active = (button.dataset.mode === 'lem') === view.lemMode;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  }
}

function renderLemHead() {
  const head = $('.code-lem-head');
  if (!head) return;
  const f = view.lemFile;
  head.replaceChildren(
    el('span', { class: 'chip code-lang' }, 'Lem'),
    el('span', { class: 'code-lem-file', title: f?.path || '' },
      // Its direction is rtl, so a long path loses its start, not its name;
      // the marks keep the path itself left to right.
      f ? `\u200e${f.path ? short(f.path) : f.name}\u200e${f.modified ? ' ●' : ''}` : 'C-x C-f visits a file · M-x runs a command'),
    el('span', { class: 'spacer' }),
    el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Find a file in Lem (C-x C-f)', onclick: () => lemRun('find-file') }, 'C-x C-f'),
    el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Run a Lem command (M-x)', onclick: () => lemRun('execute-command') }, 'M-x'),
    el('button', {
      class: 'btn btn-small btn-primary', type: 'button', 'data-doc': 'Ask the agent about this file',
      onclick: () => insertInComposer(f ? `Help me with ${short(f.path)} (open in the Lem editor).` : 'Help me with the file open in the Lem editor.'),
    }, 'Ask the agent'),
    copilotBox(focusEditor));
}

function focusEditor() { if (view.lemMode) focusLem(); else view.editor?.focus(); }

async function openDoc(kind, key, { line } = {}) {
  if (view.lemMode) {
    // Hidden, it is the file this tab opens when shown (Lem is shared).
    if (activeView() !== 'code') { view.current = { kind, key }; store('code-current', view.current); return; }
    if (kind === 'file') return lemVisit(key, line);
    const scratch = view.buffers.find(b => b.name === key);
    if (scratch) return lemVisit(scratch.path, line);
  }
  if (view.doc && view.dirty && view.doc.kind === 'scratch') await saveScratch(true);
  if (view.doc && isFile()) await syncFile();
  let doc;
  try {
    doc = kind === 'file'
      ? await api('/api/files/open', { method: 'POST', body: { path: key } })
      : await api('/api/scratch/buffer', { params: { name: key } });
  } catch (err) { message(err.message); return; }
  view.doc = { ...doc, kind, key: kind === 'file' ? doc.path : doc.name };
  view.current = { kind, key: view.doc.key };
  store('code-current', view.current);
  view.saved = doc.text;
  view.dirty = kind === 'file' ? !!doc.modified : false;
  view.diagnostics = null;
  view.triggers = [];
  renderEditor();
  renderSide();
  if (kind === 'file') loadOpenFiles();
  if (line) {
    view.editor.setCursor(view.editor.offsetOf(line - 1, 0));
  }
  view.editor?.focus();
  // Start its language server now, as Lem does on opening a file: the
  // first Tab is quicker and "." "->" open completion from the start.
  if (doc.servers?.length) {
    const route = kind === 'file' ? '/api/files/lsp-start' : '/api/scratch/lsp-start';
    api(route, { method: 'POST', body: kind === 'file' ? { path: doc.path } : { name: doc.name } })
      .then(({ triggers }) => { if (view.doc?.key === view.current.key) view.triggers = triggers; })
      .catch(err => message(err.message));
  }
}

// Scratch buffers save as you type.
async function saveScratch(now = false) {
  clearTimeout(view.saveTimer);
  if (!view.doc || isFile()) return;
  if (!now) { view.saveTimer = setTimeout(() => saveScratch(true), 700); return; }
  if (!editorOwnsDoc()) return;
  const { name } = view.doc;
  const text = view.editor.value;
  if (text === view.saved) { view.dirty = false; renderChrome(); return; }
  try {
    const { version } = await api('/api/scratch/save', { method: 'POST', body: { name, text, base: view.doc.version, client } });
    if (view.doc?.name !== name) return;
    view.doc.version = version;
    view.saved = text;
    view.dirty = view.editor.value !== text;
    if (view.dirty) saveScratch();
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const current = await api('/api/scratch/buffer', { params: { name } });
      showConflict(current.text, current.version, 'someone');
    } else message(`Not saved: ${err.message}`);
  }
  renderChrome();
}

// A file's text goes into its Lem buffer (not to disk); the reply is its
// highlighting by the buffer's own mode.
/** The simple editor holds the current document (it was made for it): only
then may its text go anywhere.  Lem moves on by itself (C-x b), and an
editor made for one file must never write another. */
const editorOwnsDoc = () => !!(view.editor && view.doc && view.editor.docKey === view.doc.key && view.editor.docKind === view.doc.kind);

async function syncFile(text) {
  if (!isFile() || !editorOwnsDoc()) return null;
  if (text === undefined) text = view.editor.value;
  const { path } = view.doc;
  try {
    const result = await api('/api/files/update', { method: 'POST', body: { path, text, base: view.doc.version, client } });
    if (view.doc?.path !== path) return null;
    view.doc.version = result.version;
    return result;
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const current = await api('/api/files/open', { method: 'POST', body: { path } });
      showConflict(current.text, current.version, 'someone');
    } else message(err.message);
    return null;
  }
}

async function saveFile({ force = false } = {}) {
  if (!isFile()) return saveScratch(true);
  const { path } = view.doc;
  await syncFile();
  try {
    const json = await api('/api/files/save', { method: 'POST', body: { path, force, client } });
    if (view.doc?.path !== path) return;
    view.doc.version = json.version;
    view.doc.newFile = false;
    if (json.text != null && json.text !== view.editor.value) view.editor.value = json.text;
    view.saved = view.editor.value;
    view.dirty = false;
    $('.code-conflict').hidden = true;
    message(`Wrote ${short(path)}`);
    loadOpenFiles();
    if (view.listing && path.startsWith(view.listing.directory)) loadDir();
  } catch (err) {
    if (/changed on disk/.test(err.message)) showDiskChanged('The file changed on disk since it was read.');
    else message(`Not saved: ${err.message}`);
  }
  renderChrome();
}

async function revertFile() {
  if (!isFile()) return;
  const json = await fileAction('/api/files/revert', { path: view.doc.path });
  if (!json) return;
  setText(json.text, json.version);
  message(`Reverted ${short(json.path)}`);
}

async function closeDoc() {
  if (!view.doc) return;
  if (!isFile()) { view.doc = null; view.current = null; store('code-current', null); renderEditor(); return; }
  const button = $('.code-close');
  if (view.dirty && button?.dataset.confirm !== view.doc.path) {
    button.dataset.confirm = view.doc.path;
    button.textContent = 'Discard changes?';
    setTimeout(() => { if (button.isConnected) { button.dataset.confirm = ''; button.textContent = 'Close'; } }, 3000);
    return;
  }
  const json = await fileAction('/api/files/close', { path: view.doc.path, force: true });
  if (!json) return;
  view.doc = null;
  view.current = null;
  store('code-current', null);
  renderEditor();
  loadOpenFiles();
}

function setText(text, version) {
  view.doc.text = text;
  view.doc.version = version;
  view.saved = text;
  view.dirty = false;
  view.editor.value = text;
  $('.code-conflict').hidden = true;
  diagnosticsStale();
  renderChrome();
}

function showConflict(text, version, by) {
  const box = $('.code-conflict');
  box.hidden = false;
  box.replaceChildren(
    el('span', {}, `${by === 'agent' ? 'The agent' : 'Someone'} changed this ${isFile() ? 'file' : 'buffer'} while you were editing.`),
    el('button', { class: 'btn btn-small', type: 'button', onclick: () => setText(text, version) }, 'Use theirs'),
    el('button', {
      class: 'btn btn-small', type: 'button',
      onclick: () => { box.hidden = true; view.doc.version = version; if (isFile()) syncFile(); else saveScratch(true); },
    }, 'Keep mine'));
}

function showDiskChanged(text) {
  const box = $('.code-conflict');
  box.hidden = false;
  box.replaceChildren(
    el('span', {}, text),
    el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Read the file again, dropping your changes', onclick: revertFile }, 'Revert'),
    el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Save your version over it', onclick: () => saveFile({ force: true }) }, 'Overwrite'));
}

async function removeScratch() {
  const { name } = view.doc || {};
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
    view.doc = null;
    renderEditor();
    await loadScratch();
    toast(`Deleted ${name} (a copy is kept in scratch/.history)`);
  } catch (err) { message(err.message); }
}

// ---------- the language server ----------

const lspBody = extra => (isFile()
  ? { path: view.doc.path, text: view.editor.value, ...extra }
  : { name: view.doc.name, ...extra });

async function check() {
  if (!view.doc) return;
  if (!isFile()) await saveScratch(true);
  const list = $('.code-diagnostics');
  list.hidden = false;
  list.replaceChildren(el('div', { class: 'faint code-diag-status' }, 'Asking the language server…'));
  try {
    const { diagnostics } = await api(isFile() ? '/api/files/diagnostics' : '/api/scratch/diagnostics',
      { method: 'POST', body: lspBody() });
    view.diagnostics = diagnostics;
  } catch (err) {
    view.diagnostics = null;
    list.replaceChildren(el('div', { class: 'code-diag-status' }, err.message));
    return;
  }
  renderDiagnostics();
}

function diagnosticsStale() {
  $('.code-diagnostics')?.classList.toggle('stale', view.diagnostics !== null);
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
      class: `code-diag sev-${d.severity}`, type: 'button', 'data-doc': 'Go to this line',
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

// Tab: a scratch buffer is saved first (its server reads the file); a file's
// unsaved text is sent to the server instead, never written.
async function complete(text, cursor) {
  if (!view.doc) return null;
  const key = view.doc.key;
  try {
    const result = isFile()
      ? await api('/api/files/complete-code', { method: 'POST', body: { path: view.doc.path, text, cursor } })
      : await api('/api/scratch/complete', { method: 'POST', body: { name: view.doc.name, text, cursor, base: view.doc.version, client } });
    if (view.doc?.key !== key) return null;
    if (!isFile()) {
      clearTimeout(view.saveTimer);
      view.doc.version = result.version;
      view.saved = text;
      view.dirty = view.editor.value !== text;
    }
    view.triggers = result.triggers || [];
    if (result.message) message(result.message);
    renderChrome();
    return result;
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const current = await api('/api/scratch/buffer', { params: { name: view.doc.name } });
      showConflict(current.text, current.version, 'someone');
      return null;
    }
    throw err;
  }
}

async function hover() {
  if (!view.doc) return;
  if (!isFile()) await saveScratch(true);
  const { line, character } = view.editor.positionOf(view.editor.cursor);
  try {
    const { text } = await api(isFile() ? '/api/files/hover' : '/api/scratch/hover',
      { method: 'POST', body: lspBody({ line, character }) });
    message(text || 'The language server has nothing to say here.', 8000);
  } catch (err) { message(err.message); }
}

// ---------- the minibuffer: find-file, dired, switch-buffer, cd ----------

const PROMPTS = {
  'find-file': 'Find file: ',
  dired: 'Dired (directory): ',
  cd: 'Change directory: ',
  'switch-buffer': 'Switch to buffer: ',
  'new-file': 'New file: ',
  'new-folder': 'New folder: ',
  command: 'M-x ',
};

// M-x: the Code tab's commands, by their Lem/Emacs names.
const COMMANDS = {
  'find-file': ['Visit a file (C-x C-f)', () => prompt('find-file')],
  dired: ['List a directory (C-x d)', () => prompt('dired')],
  'switch-to-buffer': ['Switch to an open buffer (C-x b)', () => prompt('switch-buffer')],
  'save-buffer': ['Save the buffer (C-x C-s)', () => saveFile()],
  'revert-buffer': ['Read the file again from disk', () => revertFile()],
  'kill-buffer': ['Close the buffer (C-x k)', () => closeDoc()],
  'change-directory': ['Change the working directory (cd)', () => prompt('cd')],
  cd: ['Change the working directory', () => prompt('cd')],
  'lsp-check': ['Ask the language server for problems (C-c C-c)', () => check()],
  'lsp-hover': ['The language server on the symbol at point (C-c C-d d)', () => hover()],
  'new-scratch-buffer': ['A scratch buffer in any language', () => showNew()],
};

let minibuffer = null;   // {kind, input, menu, previous}

function defaultDirectory() {
  const dir = isFile() ? view.doc.directory : (view.dir || state.session?.cwd || '');
  return dir ? (dir.endsWith('/') ? dir : `${dir}/`) : '';
}

function prompt(kind, initial) {
  const box = $('.code-minibuffer');
  const input = box.querySelector('input');
  box.hidden = false;
  box.querySelector('.code-mb-label').textContent = PROMPTS[kind];
  input.value = initial ?? (['switch-buffer', 'command'].includes(kind) ? '' : short(defaultDirectory()));
  minibuffer = { kind, input, previous: document.activeElement };
  input.focus();
  toEnd(input);
}

// Keep the end of a long path in view, where the typing happens.
function toEnd(input) {
  input.setSelectionRange(input.value.length, input.value.length);
  input.scrollLeft = input.scrollWidth;
}

function closePrompt({ restore = true } = {}) {
  if (!minibuffer) return;
  const { previous } = minibuffer;
  minibuffer = null;
  mbMenu.hide();
  $('.code-minibuffer').hidden = true;
  if (restore) (previous?.isConnected ? previous : view.editor?.input)?.focus();
}

function switchCandidates(text) {
  const all = [
    ...view.openFiles.map(f => ({ value: f.path, display: f.name, doc: short(f.directory), kind: 'file', modified: f.modified })),
    ...view.buffers.map(b => ({ value: `scratch:${b.name}`, display: b.name, doc: `scratch · ${b.language}`, kind: 'scratch' })),
  ];
  const needle = text.toLowerCase();
  return all.filter(c => c.display.toLowerCase().includes(needle) || c.value.toLowerCase().includes(needle));
}

async function completePrompt() {
  const { kind, input } = minibuffer;
  let result;
  if (kind === 'switch-buffer') {
    const candidates = switchCandidates(input.value);
    result = { start: 0, end: input.value.length, token: input.value, candidates, total: candidates.length, source: 'buffers' };
  } else if (kind === 'command') {
    const needle = input.value.toLowerCase();
    const candidates = Object.entries(COMMANDS).filter(([name]) => name.includes(needle))
      .map(([name, [doc]]) => ({ value: name, display: name, doc, kind: 'command' }));
    result = { start: 0, end: input.value.length, token: input.value, candidates, total: candidates.length, source: 'commands' };
  } else {
    result = await api('/api/files/complete', { params: { input: input.value, dir: state.session?.cwd || '' } });
    if (['dired', 'cd', 'new-folder'].includes(kind)) result.candidates = result.candidates.filter(c => c.kind === 'dir');
  }
  if (!minibuffer || minibuffer.input.value !== result.token) return;
  const { candidates } = result;
  if (!candidates.length) { mbMenu.hide(); message(`No match for ${input.value}`); return; }
  const pick = kind === 'switch-buffer' || kind === 'command';
  if (candidates.length === 1 && !pick) { input.value = candidates[0].value; toEnd(input); mbMenu.hide(); return; }
  const common = pick ? '' : commonPrefix(candidates.map(c => c.value));
  if (common.length > input.value.length) { input.value = common; toEnd(input); }
  mbMenu.show({ ...result, end: input.value.length }, pick ? 0 : -1);
}

async function submitPrompt(value) {
  const { kind } = minibuffer;
  const text = value.trim();
  closePrompt({ restore: false });
  if (!text) return;
  if (kind === 'command') {
    const command = COMMANDS[text] || Object.entries(COMMANDS).find(([name]) => name.startsWith(text))?.[1];
    if (command) command[1](); else message(`[No match] ${text}`);
    return;
  }
  if (kind === 'switch-buffer') {
    if (text.startsWith('scratch:')) await openDoc('scratch', text.slice(8));
    else await openDoc('file', text);
    return;
  }
  if (kind === 'cd') {
    const json = await fileAction('/api/cwd', { path: text });
    if (json) { message(`Working directory: ${short(json.cwd)}`); showPane('files'); loadDir(json.cwd); }
    return;
  }
  if (kind === 'new-folder' || kind === 'new-file') {
    const json = await fileAction('/api/files/create', { path: text, directory: kind === 'new-folder' });
    if (!json) return;
    if (kind === 'new-file') await openDoc('file', json.path);
    loadDir();
    return;
  }
  // find-file and dired: a directory lists, as Lem's find-file does with dired.
  if (kind === 'dired' || text.endsWith('/')) { showPane('files'); await loadDir(text); return; }
  try {
    await api('/api/files/list', { params: { dir: text } });
    showPane('files');
    await loadDir(text);
  } catch (err) {
    await openDoc('file', text);
  }
}

let mbMenu = null;

function onPromptKey(e) {
  if (!minibuffer) return;
  if (mbMenu.state) {
    const step = menuStep(e);
    if (step) {
      e.preventDefault();
      mbMenu.move(step);
      if (mbMenu.selected) minibuffer.input.value = mbMenu.selected.value;
      return;
    }
    if (menuCancel(e)) { e.preventDefault(); mbMenu.hide(); return; }
  }
  if (e.key === 'Tab' && !e.shiftKey) { e.preventDefault(); completePrompt(); return; }
  if (e.key === 'Enter') {
    e.preventDefault();
    if (mbMenu.state && mbMenu.selected) {
      const value = mbMenu.selected.value;
      mbMenu.hide();
      // Choosing a directory goes into it, as in Lem; anything else is taken.
      if (!['switch-buffer', 'command'].includes(minibuffer.kind) && value.endsWith('/')) { minibuffer.input.value = value; completePrompt(); return; }
      submitPrompt(value);
      return;
    }
    submitPrompt(minibuffer.input.value);
    return;
  }
  if (menuCancel(e)) { e.preventDefault(); closePrompt(); return; }
  if (!['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) mbMenu.hide();
}

// ---------- rendering ----------

let messageTimer = 0;
function message(text, ms = 4000) {
  const echo = $('.code-echo');
  if (!echo) return;
  echo.textContent = text;
  clearTimeout(messageTimer);
  if (ms) messageTimer = setTimeout(() => { echo.textContent = ''; }, ms);
}

function showPane(pane) {
  view.pane = pane;
  store('code-pane', pane);
  if (pane === 'files' && !view.listing) loadDir();
  if (pane === 'open') loadOpenFiles();
  if (pane === 'scratch' && view.stale) loadScratch();
  renderSide();
}

// Like dired's dates, short: the time today, the day this year, else the year.
const fmtTime = seconds => {
  if (!seconds) return '';
  const date = new Date((seconds - 2208988800) * 1000);
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  if (date.getFullYear() === now.getFullYear()) return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
  return String(date.getFullYear());
};

function renderSide() {
  const side = $('.code-side');
  if (!side) return;
  for (const tab of view.node.querySelectorAll('.code-side-tab')) tab.classList.toggle('active', tab.dataset.pane === view.pane);
  $('.code-count').textContent = short(state.session?.cwd || '');
  if (view.pane === 'files') renderFiles(side);
  else if (view.pane === 'open') renderOpen(side);
  else renderScratch(side);
}

function renderFiles(side) {
  const listing = view.listing;
  if (!listing) { side.replaceChildren(el('div', { class: 'faint code-empty' }, 'Reading…')); return; }
  const parts = listing.directory.split('/').filter(Boolean);
  const crumbs = parts.map((part, i) => el('button', {
    class: 'code-crumb', type: 'button', 'data-doc': 'Go to this directory',
    onclick: () => loadDir(`/${parts.slice(0, i + 1).join('/')}/`),
  }, part));
  const isCwd = listing.directory === listing.cwd || `${listing.directory}` === `${listing.cwd}/`;
  const rows = [
    ...(listing.parent ? [{ name: '..', path: listing.parent, directory: true, up: true }] : []),
    ...listing.entries,
  ];
  const list = el('div', { class: 'code-files', role: 'listbox', tabindex: '0', 'aria-label': 'Files' },
    rows.map((entry, i) => el('div', {
      class: `code-file ${entry.directory ? 'is-dir' : ''} ${i === view.rowIndex ? 'selected' : ''} ${view.doc?.path === entry.path ? 'current' : ''}`,
      role: 'option', title: entry.path,
      onclick: () => { view.rowIndex = i; visit(entry); },
    }, el('span', { class: 'code-file-icon' }, entry.up ? '↑' : entry.directory ? '▸' : '·'),
       el('span', { class: 'code-file-name' }, entry.directory && !entry.up ? `${entry.name}/` : entry.name, entry.link ? ' →' : ''),
       el('span', { class: 'code-file-size' }, entry.sizeText || ''),
       el('span', { class: 'code-file-time' }, fmtTime(entry.modified)),
       entry.up ? '' : el('span', { class: 'code-file-actions' },
         el('button', { class: 'btn btn-tiny', type: 'button', 'data-doc': 'Rename (R)', onclick: e => { e.stopPropagation(); renameEntry(entry); } }, 'R'),
         el('button', { class: 'btn btn-tiny btn-danger', type: 'button', 'data-doc': 'Delete (D, press twice)', onclick: e => { e.stopPropagation(); deleteEntry(entry, e.currentTarget); } }, 'D')))));
  list.addEventListener('keydown', e => onFilesKey(e, rows));
  side.replaceChildren(
    el('div', { class: 'code-dir-head' },
      el('div', { class: 'code-crumbs' }, el('button', { class: 'code-crumb', type: 'button', onclick: () => loadDir('/') }, '/'), crumbs),
      el('div', { class: 'code-dir-actions' },
        el('button', { class: 'btn btn-tiny', type: 'button', 'data-doc': 'Visit a file (C-x C-f)', onclick: () => prompt('find-file') }, 'Find…'),
        el('button', { class: 'btn btn-tiny', type: 'button', 'data-doc': 'New file here', onclick: () => prompt('new-file', short(`${listing.directory}`)) }, '+ File'),
        el('button', { class: 'btn btn-tiny', type: 'button', 'data-doc': 'New folder here', onclick: () => prompt('new-folder', short(`${listing.directory}`)) }, '+ Folder'),
        el('button', {
          class: `btn btn-tiny ${isCwd ? 'btn-primary' : ''}`, type: 'button', disabled: isCwd,
          'data-doc': isCwd ? 'This is the working directory' : 'Make this the working directory the agent\'s tools use',
          onclick: async () => { const json = await fileAction('/api/cwd', { path: listing.directory }); if (json) loadDir(); },
        }, isCwd ? 'cwd' : 'cd here'),
        el('select', {
          class: 'field code-sort', 'aria-label': 'Sort',
          onchange: e => { view.sort = e.target.value; store('code-sort', view.sort); loadDir(); },
        }, ['name', 'mtime', 'size'].map(s => el('option', { value: s, selected: s === view.sort }, s))),
        el('label', { class: 'code-hidden-toggle', 'data-doc': 'Show dot files' },
          el('input', { type: 'checkbox', checked: view.hidden, onchange: e => { view.hidden = e.target.checked; loadDir(); } }), '.*'))),
    list);
  list.querySelector('.selected')?.scrollIntoView({ block: 'nearest' });
  const crumbsNode = side.querySelector('.code-crumbs');
  if (crumbsNode) crumbsNode.scrollLeft = crumbsNode.scrollWidth;
}

function visit(entry) {
  if (entry.directory) { view.rowIndex = 0; loadDir(entry.path); } else openDoc('file', entry.path);
}

async function renameEntry(entry) {
  prompt('new-file', short(entry.path));
  minibuffer.kind = 'rename';
  $('.code-mb-label').textContent = `Rename ${entry.name} to: `;
  minibuffer.rename = entry.path;
}

async function deleteEntry(entry, button) {
  if (button.dataset.confirm !== entry.path) {
    button.dataset.confirm = entry.path;
    button.textContent = 'Delete?';
    setTimeout(() => { if (button.isConnected) { button.dataset.confirm = ''; button.textContent = 'D'; } }, 3000);
    return;
  }
  const json = await fileAction('/api/files/delete', { path: entry.path });
  if (json) { message(`Deleted ${short(json.path)}`); if (view.doc?.path === entry.path) { view.doc = null; renderEditor(); } loadDir(); }
}

// dired's keys: n/p (or C-n/C-p, arrows) move, RET/f visits, ^ goes up,
// g reads the directory again, R renames, + makes a folder.
function onFilesKey(e, rows) {
  if (e.altKey || e.metaKey) return;
  const n = rows.length;
  const row = rows[view.rowIndex];
  const move = d => { view.rowIndex = Math.max(0, Math.min(n - 1, view.rowIndex + d)); renderSide(); $('.code-files')?.focus(); };
  const ctrl = e.ctrlKey;
  const act = fn => { e.preventDefault(); fn(); };
  if (e.key === 'ArrowDown' || (!ctrl && e.key === 'n') || (ctrl && e.code === 'KeyN')) act(() => move(1));
  else if (e.key === 'ArrowUp' || (!ctrl && e.key === 'p') || (ctrl && e.code === 'KeyP')) act(() => move(-1));
  else if (ctrl) return;
  else if (e.key === 'Enter' || e.key === 'f') act(() => row && visit(row));
  else if (e.key === '^' || e.key === 'Backspace') act(() => { if (view.listing?.parent) { view.rowIndex = 0; loadDir(view.listing.parent); } });
  else if (e.key === 'g') act(() => loadDir());
  else if (e.key === 'R' && row && !row.up) act(() => renameEntry(row));
  else if (e.key === '+') act(() => prompt('new-folder', short(view.listing.directory)));
}

function renderOpen(side) {
  if (!view.openFiles.length) {
    side.replaceChildren(el('div', { class: 'empty code-empty' }, 'No files open. ',
      el('button', { class: 'btn btn-small', type: 'button', onclick: () => prompt('find-file') }, 'Find file (C-x C-f)')));
    return;
  }
  side.replaceChildren(el('div', { class: 'code-list', role: 'listbox', 'aria-label': 'Open files' },
    view.openFiles.map(f => el('div', {
      class: `code-row ${view.doc?.path === f.path ? 'selected' : ''}`, role: 'option', title: f.path,
      onclick: () => openDoc('file', f.path),
    }, el('span', { class: 'code-row-name' }, f.modified ? '● ' : '', f.name),
       el('span', { class: 'chip code-lang' }, f.mode || 'text'),
       el('span', { class: 'faint code-row-file' }, short(f.directory))))));
}

function renderScratch(side) {
  const form = el('form', { class: 'code-new', hidden: true, onsubmit: e => { e.preventDefault(); submitNew(); } },
    el('input', { class: 'field', placeholder: 'name, e.g. hello', spellcheck: 'false', 'aria-label': 'Buffer name',
      onkeydown: e => { if (e.key === 'Escape') form.hidden = true; } }),
    el('select', { class: 'field', 'aria-label': 'Language' }),
    el('button', { class: 'btn btn-small btn-primary', type: 'submit' }, 'Create'));
  const items = view.buffers.length
    ? view.buffers.map(b => el('div', {
      class: `code-row ${view.doc?.kind === 'scratch' && view.doc.name === b.name ? 'selected' : ''}`, role: 'option',
      onclick: () => openDoc('scratch', b.name),
    }, el('span', { class: 'code-row-name' }, b.name),
       el('span', { class: 'chip code-lang' }, b.language || b.extension),
       el('span', { class: 'faint code-row-file' }, `.${b.extension}`)))
    : [el('div', { class: 'empty code-empty' },
      'No scratch buffers yet. ', el('button', { class: 'btn btn-small', type: 'button', onclick: showNew }, 'New buffer'),
      el('p', { class: 'faint' }, 'Write C, Ruby, Python, Rust… with Lem\'s highlighting, the language server\'s diagnostics, and the agent\'s help.'))];
  side.replaceChildren(
    el('div', { class: 'code-dir-head' }, el('span', { class: 'faint' }, 'scratch/'),
      el('div', { class: 'code-dir-actions' }, el('button', { class: 'btn btn-tiny', type: 'button', onclick: showNew }, '+ Scratch'))),
    form, el('div', { class: 'code-list', role: 'listbox', 'aria-label': 'Scratch buffers' }, items));
}

function showNew() {
  if (view.pane !== 'scratch') showPane('scratch');
  const form = $('.code-new');
  form.hidden = false;
  const select = form.querySelector('select');
  if (!select.options.length) {
    select.append(...view.languages.map(l => el('option', { value: l.name }, `${l.name} (.${l.extension})`)));
    select.value = storage('code-language', 'C');
  }
  form.querySelector('input').focus();
}

function submitNew() {
  const form = $('.code-new');
  const language = form.querySelector('select').value;
  store('code-language', language);
  createScratch(form.querySelector('input').value.trim(), language);
}

function renderChrome() {
  const chip = $('.code-state');
  if (!chip || !view.doc) return;
  const [text, color] = isFile()
    ? (view.doc.newFile ? ['NEW FILE', 'fill-orange'] : view.dirty ? ['MODIFIED', 'fill-orange'] : ['SAVED', 'fill-green'])
    : (view.dirty ? ['EDITED', 'fill-orange'] : ['SAVED', 'fill-green']);
  chip.textContent = text;
  chip.className = `chip code-state ${color}`;
}

function renderEditor() {
  const lem = $('.code-lem');
  if (lem) lem.hidden = !view.lemMode;
  const pane = $('.code-simple');
  if (!pane) return;
  pane.hidden = view.lemMode;
  if (view.lemMode) { renderLemHead(); return; }
  // A document known only by name (what Lem showed) has no text here yet:
  // an editor made now would hold "" -- and sync it.  OPENDOC reads it.
  if (view.doc && typeof view.doc.text !== 'string') {
    view.editor = null;
    pane.replaceChildren(el('div', { class: 'session-preview-empty code-welcome' }, `Opening ${view.doc.name || ''}…`));
    return;
  }
  if (!view.doc) {
    view.editor = null;
    pane.replaceChildren(el('div', { class: 'session-preview-empty code-welcome' },
      el('div', {}, 'Visit a file with ', el('kbd', {}, 'C-x C-f'), ', browse with ', el('kbd', {}, 'C-x d'), ', or pick one on the left.'),
      el('div', { class: 'faint' }, 'Files open in Lem: its modes, your Lem init file, its save settings. C-x C-s saves.')));
    return;
  }
  const d = view.doc;
  const file = isFile();
  const language = file ? (d.mode || 'Text') : (d.language || d.extension);
  const servers = d.servers?.length ? d.servers.join(', ') : null;
  const host = el('div', { class: 'code-editor-host' });
  const button = (label, doc, onclick, cls = '') => el('button', { class: `btn btn-small ${cls}`, type: 'button', 'data-doc': doc, onclick }, label);
  pane.replaceChildren(
    el('div', { class: 'session-head code-head' },
      el('div', { class: 'session-head-title' },
        el('span', { class: 'session-head-name' }, file ? d.name : d.name),
        el('span', { class: 'chip code-lang' }, language),
        el('span', { class: 'chip code-state fill-green' }, 'SAVED')),
      el('div', { class: 'session-head-meta', title: d.path, 'data-doc': d.path },
        file ? short(d.path) : `scratch/${d.name}.${d.extension}`,
        el('span', { class: servers ? 'code-lsp on' : 'code-lsp' },
          servers ? ` · language server: ${servers}` : file && d.newFile ? ' · save to start its language server' : ' · no language server')),
      el('div', { class: 'session-head-actions' },
        button('Save', 'Save (C-x C-s)', () => saveFile()),
        file ? button('Revert', 'Read the file again from disk, dropping unsaved changes', revertFile) : '',
        el('button', {
          class: 'btn btn-small', type: 'button', disabled: !servers,
          'data-doc': servers ? 'Ask the language server for problems (C-c C-c)' : 'Configure a language server for this file type in lsp.sexp',
          onclick: check,
        }, 'Check'),
        button('Ask the agent', 'Ask the agent about this file (or the selected lines)', () => {
          const { start, end, text } = view.editor.selection;
          const what = file ? short(d.path) : `my ${language} scratch buffer "${d.name}"`;
          insertInComposer(text.trim()
            ? `Look at lines ${view.editor.lineOf(start)}–${view.editor.lineOf(end)} of ${what}.`
            : `Help me with ${what}.`);
        }, 'btn-primary'),
        el('span', { class: 'spacer' }),
        copilotBox(focusEditor),
        file
          ? el('button', { class: 'btn btn-small code-close', type: 'button', 'data-doc': 'Close this buffer (C-x k)', onclick: closeDoc }, 'Close')
          : el('button', { class: 'btn btn-small btn-danger code-delete', type: 'button', 'data-doc': 'Delete this buffer (press twice)', onclick: removeScratch }, 'Delete'))),
    el('div', { class: 'scratch-conflict code-conflict', hidden: true }),
    host,
    el('div', { class: 'code-diagnostics', hidden: true }));
  const editor = view.editor = createLispEditor(host, {
    className: 'code-editor',
    value: d.text,
    doc: `${language} · Tab complete · C-c Tab copilot · C-x C-s save · C-x C-f find file · C-x b switch · C-c C-c check · C-c C-d d hover · M-/ expand`,
    highlight: file
      ? async text => (editor.docKey === view.doc?.key ? (await syncFile(text))?.runs : null)
      : async text => (await api('/api/highlight', { method: 'POST', body: { text, pathname: `x.${d.extension}` } })).runs,
    indentUnit: INDENT[language] || 2,
    wordPattern: /[\w$]/,
    complete,
    triggerCharacters: () => view.triggers,
    ...copilotOptions(() => view.doc?.path || `scratch.${view.doc?.extension || 'txt'}`),
    keymap: {
      'C-x C-s': () => saveFile(),
      'C-x C-f': () => prompt('find-file'),
      'C-x d': () => prompt('dired'),
      'C-x b': () => prompt('switch-buffer'),
      'C-x k': closeDoc,
      'C-c C-c': check,
      'C-c C-d d': hover,
      'C-c C-d C-d': hover,
      'M-x': () => prompt('command'),
    },
    onChange: text => {
      view.dirty = file ? text !== view.saved : true;
      diagnosticsStale();
      renderChrome();
      if (!file) saveScratch();
    },
    onMessage: text => (text ? message(text, 2500) : null),
  });
  editor.docKey = d.key;
  editor.docKind = d.kind;
  renderChrome();
  renderDiagnostics();
}

function mount(node) {
  view.node = node;
  const input = el('input', { class: 'code-mb-input', spellcheck: 'false', autocomplete: 'off', 'aria-label': 'Minibuffer' });
  const menuNode = el('div', { class: 'completions code-mb-menu', hidden: true });
  mbMenu = createMenu(menuNode, {
    onAccept: candidate => {
      if (!minibuffer) return;
      if (!['switch-buffer', 'command'].includes(minibuffer.kind) && candidate.value.endsWith('/')) {
        minibuffer.input.value = candidate.value;
        mbMenu.hide();
        minibuffer.input.focus();
        completePrompt();
      } else submitPrompt(candidate.value);
    },
  });
  input.addEventListener('keydown', e => {
    if (minibuffer?.kind === 'rename' && e.key === 'Enter') {
      e.preventDefault();
      const from = minibuffer.rename;
      const to = input.value.trim();
      closePrompt();
      fileAction('/api/files/rename', { from, to }).then(json => { if (json) { loadDir(); loadOpenFiles(); } });
      return;
    }
    onPromptKey(e);
  });
  input.addEventListener('blur', () => setTimeout(() => {
    if (minibuffer && !$('.code-minibuffer').contains(document.activeElement)) closePrompt({ restore: false });
  }, 150));
  const tab = (pane, label, doc) => el('button', {
    class: 'code-side-tab', type: 'button', 'data-pane': pane, 'data-doc': doc, onclick: () => showPane(pane),
  }, label);
  node.append(
    el('div', { class: 'subpane-title sessions-toolbar code-toolbar' },
      el('span', { class: 'subpane-name' }, 'Code'),
      el('span', { class: 'subpane-info code-count', 'data-doc': 'The working directory (M-x cd changes it)' }, ''),
      el('span', { class: 'spacer' }),
      el('span', { class: 'code-editor-switch', role: 'group', 'aria-label': 'Editor' },
        el('button', { class: 'btn btn-small', type: 'button', 'data-mode': 'lem', 'data-doc': 'Edit in Lem itself: its keys, modes, M-x, windows and your init file',
                       onclick: () => setLemMode(true) }, 'Lem'),
        el('button', { class: 'btn btn-small', type: 'button', 'data-mode': 'simple', 'data-doc': 'Edit in the lightweight editor instead',
                       onclick: () => setLemMode(false) }, 'Simple')),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Visit a file (C-x C-f)', onclick: () => (view.lemMode ? lemRun('find-file') : prompt('find-file')) }, 'Find file'),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Switch to an open buffer (C-x b)', onclick: () => (view.lemMode ? lemRun('select-buffer') : prompt('switch-buffer')) }, 'Buffers'),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Change the working directory (M-x cd)', onclick: () => prompt('cd') }, 'cd')),
    el('div', { class: 'sessions-split code-split' },
      el('div', { class: 'subpane code-list-pane' },
        el('div', { class: 'code-side-tabs' },
          tab('files', 'Files', 'The directory, as Lem\'s dired lists it'),
          tab('open', 'Open', 'Files open in the editor'),
          tab('scratch', 'Scratch', 'Scratch buffers in any language')),
        el('div', { class: 'code-side' })),
      el('div', { class: 'subpane code-editor-pane' },
        el('div', { class: 'code-lem', hidden: true },
          el('div', { class: 'code-lem-head' }),
          el('div', { class: 'code-lem-host' })),
        el('div', { class: 'code-simple' }))),
    el('div', { class: 'code-minibuffer', hidden: true },
      menuNode,
      el('label', { class: 'code-mb-label' }, ''), input),
    el('div', { class: 'echo-area code-echo' }));
  // C-x chords work in the file list too, not only in the editor.
  let pendingX = false;
  node.addEventListener('keydown', e => {
    if (e.defaultPrevented || e.target.closest('.lisp-editor') || e.target.closest('.code-minibuffer') || e.target.matches('input, select, textarea')) return;
    const ctrl = e.ctrlKey && !e.altKey && !e.metaKey;
    if (pendingX) {
      pendingX = false;
      const action = view.lemMode
        ? { KeyF: ctrl && (() => lemRun('find-file')), KeyD: () => lemRun('filer'), KeyB: () => lemRun('select-buffer') }[e.code]
        : { KeyF: ctrl && (() => prompt('find-file')), KeyD: () => prompt('dired'), KeyB: () => prompt('switch-buffer'), KeyS: ctrl && (() => saveFile()) }[e.code];
      if (action) { e.preventDefault(); action(); }
      return;
    }
    if (ctrl && e.code === 'KeyX') { e.preventDefault(); pendingX = true; message('C-x-', 1500); }
  });
  renderSide();
  renderEditor();
  renderToolbar();
  showPane(view.pane);
  loadScratch();
  loadOpenFiles();
  lemView = createLemView($('.code-lem-host'), { wanted: () => view.lemMode && !!view.node, message });
  if (view.lemMode) ensureLemFrame();
  if (view.current) openDoc(view.current.kind, view.current.key);
}

registerView({
  id: 'code', title: 'Code', color: 'orange', order: 15,
  doc: 'Your files, edited through Lem (C-x C-f), and scratch buffers in any language, shared with the agent (Alt-C)',
  mount,
  show: () => {
    if (view.stale) loadScratch();
    // Lem is shared with the Lisp tab's scratch buffer: put this tab's file back.
    if (view.lemMode) {
      ensureLemFrame().then(() => { lemRemeasure(); focusLem(); });
      if (view.current) openDoc(view.current.kind, view.current.key);
    }
    else setTimeout(() => (view.editor?.input || $('.code-files'))?.focus(), 0);
  },
});

// What Lem's window shows -- visited here, with C-x C-f or C-x b in Lem,
// by the agent -- is the current file; its modified state the Open dot.
on('lem-buffer', ev => {
  const open = ev.path && view.openFiles.find(f => f.path === ev.path);
  if (open && open.modified !== ev.modified) open.modified = ev.modified;
  else if (ev.path && !open) loadOpenFiles();
  view.lemShown += 1;
  // Only while this tab is the one in front: the Lisp tab shows its scratch
  // buffer in the same Lem.
  if (view.lemMode && view.node && activeView() === 'code') noteLemShown(ev);
});

// ---------- what other pages and the agent change ----------

on('scratch-buffer', ev => {
  const b = view.buffers.find(x => x.name === ev.name);
  if (b) b.size = ev.text.length;
  if (ev.client === client || view.doc?.kind !== 'scratch' || view.doc.name !== ev.name || !editorOwnsDoc()) return;
  if (view.dirty && view.editor.value !== ev.text) { showConflict(ev.text, ev.version, ev.by); return; }
  setText(ev.text, ev.version);
  if (ev.by === 'agent') message('The agent updated this buffer.');
});

on('scratch-buffers', ev => {
  view.stale = true;
  if (view.node) loadScratch();
  if (ev.created && ev.by === 'agent') toast(`The agent made the scratch buffer ${ev.created}`);
});

on('file-buffer', ev => {
  const open = view.openFiles.find(f => f.path === ev.path);
  if (open && ev.modified != null) { open.modified = ev.modified; if (view.pane === 'open') renderSide(); }
  // In Lem the buffer is on screen itself: only the simple editor follows.
  if (ev.client === client || !isFile() || view.doc.path !== ev.path || !editorOwnsDoc()) return;
  if (ev.changedOnDisk) { showDiskChanged(`${ev.by === 'agent' ? 'The agent' : 'Someone'} changed this file on disk; you have unsaved changes.`); return; }
  if (ev.text == null) { if (ev.saved) { view.saved = view.editor.value; view.dirty = false; renderChrome(); } return; }
  if (view.dirty && view.editor.value !== ev.text) { showConflict(ev.text, ev.version, ev.by); return; }
  setText(ev.text, ev.version);
  if (ev.saved) view.dirty = false;
  if (ev.by === 'agent') message('The agent changed this file; it was read again.');
  renderChrome();
});

on('file-buffers', () => { if (view.node) loadOpenFiles(); });
on('files-changed', ev => { if (view.listing && ev.directory?.replace(/\/?$/, '/') === view.listing.directory.replace(/\/?$/, '/')) loadDir(); });
on('cwd', ev => {
  const old = state.session?.cwd;
  if (state.session) state.session.cwd = ev.cwd;
  // A listing of the old working directory follows it to the new one.
  const same = (a, b) => a && b && a.replace(/\/?$/, '/') === b.replace(/\/?$/, '/');
  if (view.node && same(view.dir, old)) loadDir(ev.cwd);
  if (view.node) { renderSide(); if (ev.by === 'agent') toast(`The agent changed the working directory to ${short(ev.cwd)}`); }
});

// open-in-editor: the agent shows the user a file.
registerUICommand('open-file', args => {
  showView('code');
  openDoc('file', args.path, { line: args.line || undefined });
});
