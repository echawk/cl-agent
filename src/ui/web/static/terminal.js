// terminal.js -- the Terminal tab: shells next to your files, run by slt, a
// terminal emulator in Common Lisp, in the agent's image (terminal.lisp),
// and drawn here by slt's own browser client (slt-terminal.js, served at
// /api/terminal/slt-terminal.js).  Each terminal talks to its shell over a
// WebSocket of its own; this module keeps the tabs, the theme and the keys.
//
//   /term [dir]     a terminal in DIR (the working directory), shown here
//   /shell [@file]  save a file and run it in a terminal in its directory
//   Ask             the terminal's last lines at the main prompt (Ctrl-Shift-A)
//
// In a terminal every key is the program's -- Alt is Meta, Ctrl-C
// interrupts -- but for Ctrl-Shift-A (ask) and Ctrl-Shift-P (to the prompt).
// The page's own Alt- keys step aside (main.js).

import { on, emit, el, api, state, registerView, registerCommand } from './core.js';
import { insert as insertInComposer } from './composer.js';
import { showView, activeView } from './views.js';
import { present } from './objects.js';
import { currentFile } from './code.js';

const toast = (text, color) => window.CLAgent?.toast(text, color);

const view = {
  node: null,
  list: [],               // the server's terminals: {id, title, directory, state, url, problem}
  shown: new Map(),       // id -> {terminal (SltTerminal), node}
  active: null,           // the id in front
};

const $ = sel => view.node?.querySelector(sel);

// ---------- slt's client ----------

let client = null;
const loadClient = () => (client ??= import('/api/terminal/slt-terminal.js'));

/** The page's colours and font as an slt theme (any page theme, mono too). */
function pageTheme() {
  const css = getComputedStyle(document.documentElement);
  const v = name => css.getPropertyValue(`--${name}`).trim();
  const ink = v('ink'), paper = v('paper');
  // ANSI 0-7 and their bright twins: black is the ink, white the soft rule.
  const ansi = [ink, v('red'), v('green'), v('orange'), v('blue'), v('pink'), v('cyan'), v('rule-soft')];
  return {
    foreground: ink, background: paper, cursor: ink, cursorText: paper,
    selection: 'rgba(128, 128, 128, 0.35)',
    palette: [...ansi, ...ansi],
    boldIsBright: false,
    fontFamily: v('font'), fontSize: v('font-size'),
  };
}

function restyle() {
  const theme = pageTheme();
  for (const { terminal } of view.shown.values()) terminal.setTheme(theme);
}

// ---------- the terminals ----------

async function load() {
  try { setList((await api('/api/terminals')).terminals); } catch (err) { /* the server is starting */ }
}

function setList(list) {
  view.list = list;
  emit('views');          // the tab's badge: how many are running
  if (!view.node) return;
  for (const [id, shown] of view.shown) {
    if (!list.some(t => t.id === id)) { shown.terminal.dispose(); shown.node.remove(); view.shown.delete(id); }
  }
  if (!list.some(t => t.id === view.active)) view.active = list.at(-1)?.id ?? null;
  render();
}

async function ensureShown(entry) {
  if (view.shown.has(entry.id) || !entry.url) return view.shown.get(entry.id);
  const { SltTerminal } = await loadClient();
  if (view.shown.has(entry.id)) return view.shown.get(entry.id);
  const node = el('div', { class: 'term-screen', dataset: { id: entry.id }, hidden: entry.id !== view.active });
  $('.term-host').append(node);
  const terminal = new SltTerminal(node, { url: entry.url, theme: pageTheme() });
  terminal.addEventListener('title', () => renderTabs());
  terminal.addEventListener('exit', () => load());
  const shown = { terminal, node };
  view.shown.set(entry.id, shown);
  return shown;
}

function render() {
  renderTabs();
  for (const entry of view.list) ensureShown(entry);
  for (const [id, { node }] of view.shown) node.hidden = id !== view.active;
  const empty = !view.list.length;
  $('.term-empty').hidden = !empty;
  const entry = current();
  $('.term-where').textContent = entry ? `${entry.directory}${entry.state === 'exited' ? ' · exited' : ''}` : '';
  for (const button of view.node.querySelectorAll('.term-needs-one')) button.disabled = !entry;
  focusActive();
}

function renderTabs() {
  const tabs = $('.term-tabs');
  if (!tabs) return;
  tabs.replaceChildren(...view.list.map(entry => {
    const title = view.shown.get(entry.id)?.terminal.title
      || entry.directory.replace(/\/$/, '').split('/').pop() || '/';
    const tab = el('button', {
      class: `term-tab ${entry.id === view.active ? 'active' : ''} ${entry.state === 'exited' ? 'exited' : ''}`,
      type: 'button', role: 'tab', 'aria-selected': String(entry.id === view.active),
      onclick: () => select(entry.id),
    }, `${entry.id} ${title}`);
    present(tab, () => terminalObject(entry), { left: 'Show' });
    return tab;
  }));
}

const current = () => view.list.find(t => t.id === view.active);

function select(id) {
  view.active = id;
  render();
}

function focusActive() {
  if (activeView() !== 'terminal') return;
  const shown = view.shown.get(view.active);
  if (shown) setTimeout(() => { shown.terminal.fit(); shown.terminal.focus(); }, 0);
}

/** The rows and columns a new terminal fills: its shell starts that size,
 *  so what runs first is not wrapped at 80 columns. */
function hostSize() {
  const host = $('.term-host');
  if (!host?.clientWidth) return {};
  const theme = pageTheme();
  const probe = el('span', { style: { position: 'absolute', visibility: 'hidden', whiteSpace: 'pre', font: `${theme.fontSize} ${theme.fontFamily}` } }, 'M'.repeat(20));
  host.append(probe);
  const width = probe.getBoundingClientRect().width / 20;
  const height = Math.ceil((parseFloat(theme.fontSize) || 14) * 1.2);   // slt's line height
  probe.remove();
  // .term-screen's inset: 6px above and below, 8px either side.
  return width ? { rows: Math.max(2, Math.floor((host.clientHeight - 12) / height)),
                   cols: Math.max(2, Math.floor((host.clientWidth - 16) / width)),
                   // Until the page connects (slt's client sends its cells then):
                   // what a program prints first is laid out in these.
                   cellWidth: Math.round(width), cellHeight: height } : {};
}

/** Open (or show) a terminal: BODY is {directory, new} or {file} (run it). */
export async function openTerminal(body = {}) {
  showView('terminal');
  const entry = await api('/api/terminal', { method: 'POST', body: { ...hostSize(), ...body } });
  if (!view.list.some(t => t.id === entry.id)) setList([...view.list, entry]);
  view.active = entry.id;
  if (view.node) render();
  return entry;
}

export const runFile = path => openTerminal({ file: path });

async function closeTerminal(id) {
  try { await api('/api/terminal/close', { method: 'POST', body: { id } }); } catch (err) { toast(err.message, 'red'); }
  await load();
}

export async function askAboutTerminal(id = view.active) {
  try {
    const { prompt } = await api('/api/terminal/transcript', { params: id != null ? { id } : {} });
    insertInComposer(prompt);
  } catch (err) { toast(err.message, 'red'); }
}

function terminalObject(entry) {
  const shown = view.shown.get(entry.id);
  return {
    kind: 'Terminal', title: `Terminal ${entry.id}`, type: 'TERMINAL', text: entry.directory,
    parts: [['directory', entry.directory], ['title', shown?.terminal.title || entry.title], ['state', entry.state],
            ['size', shown ? `${shown.terminal.cols}×${shown.terminal.rows}` : '—']],
    commands: [
      { label: 'Show', run: () => { showView('terminal'); select(entry.id); } },
      { label: 'Ask the agent about it', doc: 'Ctrl-Shift-A', run: () => askAboutTerminal(entry.id) },
      { label: 'New terminal here', run: () => openTerminal({ directory: entry.directory, new: true }).catch(err => toast(err.message, 'red')) },
      { label: 'Close', danger: true, run: () => closeTerminal(entry.id) },
    ],
  };
}

// ---------- the tab ----------

function mount(node) {
  view.node = node;
  node.append(
    el('div', { class: 'term-bar' },
      el('div', { class: 'term-tabs', role: 'tablist', 'aria-label': 'Terminals' }),
      el('span', { class: 'term-where' }),
      el('span', { class: 'spacer' }),
      el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'A new terminal in the working directory (/term)',
                     onclick: () => openTerminal({ new: true }).catch(err => toast(err.message, 'red')) }, '+ New'),
      el('button', { class: 'btn btn-small btn-ask term-needs-one', type: 'button', 'aria-label': 'Ask the agent about this terminal',
                     'data-doc': 'Its last lines at the prompt, to ask the agent about them (Ctrl-Shift-A)',
                     onclick: () => askAboutTerminal() }, 'Ask'),
      el('button', { class: 'btn btn-small term-needs-one', type: 'button', 'data-doc': 'Close this terminal: its shell is hung up',
                     onclick: () => view.active != null && closeTerminal(view.active) }, 'Close')),
    el('div', { class: 'term-host' },
      el('div', { class: 'term-empty' },
        el('p', {}, ';; No terminal yet.'),
        el('p', {}, '/term [dir] opens one; /shell @file saves a file and runs it here. ',
          'In a terminal every key is the program\'s -- Ctrl-C interrupts it -- but Ctrl-Shift-A, which asks the agent about what it shows, and Ctrl-Shift-P, back to the prompt.'),
        el('button', { class: 'btn', type: 'button', onclick: () => openTerminal().catch(err => toast(err.message, 'red')) }, 'Open a terminal'))));
  // Before slt's own key handling: the two keys that are not the program's.
  node.addEventListener('keydown', e => {
    if (!(e.ctrlKey && e.shiftKey && !e.altKey && !e.metaKey)) return;
    if (e.code === 'KeyA') { e.preventDefault(); e.stopPropagation(); askAboutTerminal(); }
    else if (e.code === 'KeyP') { e.preventDefault(); e.stopPropagation(); document.getElementById('input')?.focus(); }
  }, true);
  new ResizeObserver(() => view.shown.get(view.active)?.terminal.fit()).observe($('.term-host'));
  load();
  render();
}

registerView({
  id: 'terminal', title: 'Terminal', color: 'cyan', order: 17,
  doc: 'Shells next to your files, run by slt: run programs, then ask the agent about what they printed (/term, /shell)',
  badge: () => { const n = view.list.filter(t => t.state === 'running').length; return n ? String(n) : ''; },
  mount,
  show: () => { load(); focusActive(); },
});

on('terminals', ev => { setList(ev.terminals); });
on('theme', () => setTimeout(restyle, 0));
load();

// ---------- the prompt's commands ----------

/** /term and /shell's argument: a path relative to the working directory. */
function promptPath(arg) {
  const path = arg.trim().replace(/^@/, '');
  if (!path) return null;
  const cwd = (state.session?.cwd || '').replace(/\/?$/, '/');
  return path.startsWith('/') || path.startsWith('~') ? path : cwd + path;
}

registerCommand('term', arg => openTerminal({ directory: promptPath(arg) || undefined }),
  'A terminal in the Terminal tab: /term [dir] (Ctrl-Shift-A in it asks about it)');

registerCommand('shell', arg => {
  const path = promptPath(arg) || currentFile();
  if (!path) throw new Error('Usage: /shell @file (or with a file open in the Code tab): save it and run it in a terminal');
  return runFile(path);
}, 'Save a file and run it in a terminal by its type: /shell [@file] (C, C++, Rust, Go, Python, Ruby, Racket, JS, Lisp, shell...)');
