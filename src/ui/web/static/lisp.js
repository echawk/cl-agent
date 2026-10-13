// lisp.js -- the Lisp tab: a SLY-style REPL on the agent's own image beside
// a scratch buffer the agent can read and edit too (server side:
// ui/web/lisp-repl.lisp, lisp-introspect.lisp, lisp-routes.lisp).
//
//   scratch    a Lisp buffer saved to ~/.config/cl-agent/repl/scratch.lisp
//              as you type; the agent's edits (lisp-scratch-write) appear
//              live, and a clash with unsaved typing asks which to keep
//   REPL       evaluates on its own thread; output streams in, values are
//              presentations (click: inspect, Alt-click: insert a
//              reference), errors open the debugger with real restarts
//   echo area  the argument list of the call at the cursor, and messages
//   Inspect    a side panel for drilling into any presented value
//
// Keys, SLY's as far as a browser allows (both editors unless marked):
//   Tab  indent or complete     RET  (REPL) evaluate a complete input
//   C-M-i  complete             M-/  expand a word from the buffers (dabbrev)
//   M-p M-n  (REPL) history     C-c C-c  compile form (scratch) / interrupt (REPL)
//   C-x C-e  eval form before   C-M-x  (scratch) eval toplevel form
//   C-c C-k  compile & load the scratch buffer      C-c C-z  scratch <-> REPL
//   C-c C-d d / h / a  describe / HyperSpec / apropos     M-.  find definition
//   C-c RET  macroexpand-1      C-c M-m  macroexpand-all   C-c I  inspect
//   C-c M-o  clear the REPL

import {
  state, on, el, api, registerView, registerPanel, storage, store, fmtDuration,
} from './core.js';
import { createLispEditor, highlight, isComplete } from './lisp-editor.js';
import { showPanel } from './panels.js';
import { insert as insertInComposer } from './composer.js';
import { showView, activeView } from './views.js';
import { copilotBox, copilotOptions } from './copilot.js';

const toast = (text, color) => window.CLAgent?.toast(text, color);
const client = Math.random().toString(36).slice(2);

const lisp = {
  mounted: false,
  package: 'CL-AGENT',
  busy: false,
  entries: new Map(),          // id -> entry, in order
  scratch: { text: '', version: 0, path: '' },
  agentEdited: false,
};
let ui = null;                 // DOM and editors, once mounted

// ---------- small pieces ----------

const code = text => {
  const node = el('pre', { class: 'lisp-code' });
  node.innerHTML = highlight(text);
  return node;
};

function reference(id) {
  return lisp.package === 'CL-AGENT' ? `(lisp-repl-object ${id})` : `(cl-agent::lisp-repl-object ${id})`;
}

function presentation(text, id, type = '') {
  if (!id) return el('span', {}, text);
  return el('span', {
    class: 'presentation mouse',
    'data-doc': `${type ? `${type} · ` : ''}Click: inspect · Alt-click: put ${reference(id)} in the REPL input`,
    onclick: e => {
      if (e.altKey) { ui?.repl.insert(reference(id)); ui?.repl.focus(); } else inspect(id);
    },
  }, text);
}

function message(text, ms = 4000) {
  if (!ui) return;
  ui.echo.classList.add('message');
  ui.echo.replaceChildren(text);
  clearTimeout(ui.echoTimer);
  ui.echoTimer = setTimeout(() => { ui.echo.classList.remove('message'); renderAutodoc(); }, ms);
}

function nearBottom() {
  const t = ui.transcript;
  return t.scrollHeight - t.scrollTop - t.clientHeight < 60;
}
function scrollToEnd() { ui.transcript.scrollTop = ui.transcript.scrollHeight; }

// ---------- the transcript ----------

function entryNode(entry) {
  const node = el('div', { class: `lisp-entry state-${entry.state} source-${entry.source}`, 'data-id': entry.id });
  const input = entry.mode === 'compile-file' ? ';; compile and load the scratch buffer' : entry.input.replace(/\s+$/, '');
  node.append(el('div', { class: 'lisp-in' },
    el('span', { class: 'lisp-prompt' }, `${entry.package}>`),
    code(input),
    entry.source === 'scratch' ? el('span', { class: 'chip fill-paper lisp-from', 'data-doc': 'Sent from the scratch buffer' }, entry.mode === 'compile' ? 'compiled' : 'scratch') : ''));
  node.append(el('pre', { class: 'lisp-output', hidden: !entry.output }, entry.output));
  for (const note of entry.notes) {
    node.append(el('div', { class: `lisp-note ${note.severity}` }, `; ${note.severity}: ${note.message}`));
  }
  const d = entry.debugger;
  if (entry.state === 'running') {
    node.append(el('div', { class: 'lisp-running' }, el('span', { class: 'run-bar' }), ' evaluating… ',
      el('button', { class: 'btn btn-small btn-danger', type: 'button', onclick: interrupt, 'data-doc': 'Break into the evaluation (C-c C-c)' }, 'Interrupt')));
  } else if (entry.state === 'debugger') {
    node.append(debuggerNode(entry));
  } else if (entry.state === 'aborted') {
    node.append(el('div', { class: 'lisp-aborted' }, `; Evaluation aborted${d ? ` on #<${d.type}>` : ''}`));
    if (d) node.append(conditionDetails(d));
  } else {
    if (d) node.append(el('details', { class: 'lisp-recovered' }, el('summary', {}, `; recovered from ${d.type}: ${d.condition.split('\n')[0]}`), conditionDetails(d, true)));
    if (!entry.values.length) node.append(el('div', { class: 'lisp-none' }, '; No values'));
    for (const value of entry.values) {
      node.append(el('div', { class: 'lisp-value' }, presentation(value.text, value.id, value.type)));
    }
    if (entry.elapsed >= 0.2) node.append(el('div', { class: 'lisp-elapsed' }, `; ${entry.elapsed < 60 ? `${entry.elapsed.toFixed(2)} s` : fmtDuration(entry.elapsed)}`));
  }
  return node;
}

function conditionDetails(d, bare = false) {
  return el(bare ? 'div' : 'details', { class: 'dbg-details' },
    bare ? '' : el('summary', {}, `${d.type}: ${d.condition.split('\n')[0]}`),
    el('pre', { class: 'dbg-condition-text' }, d.condition),
    el('ol', { class: 'dbg-frames', start: 0 }, d.backtrace.map(frame => el('li', {}, code(frame)))));
}

function debuggerNode(entry) {
  const d = entry.debugger;
  const value = el('input', {
    class: 'field dbg-input', type: 'text', spellcheck: 'false',
    placeholder: 'a value, for restarts that ask (USE-VALUE, STORE-VALUE): read and evaluated',
    'data-doc': 'Restarts that need a value read this form',
  });
  const choose = choice => api('/api/lisp/choose', { method: 'POST', body: { choice, input: value.value } })
    .catch(err => toast(err.message, 'red'));
  const box = el('div', {
    class: 'debugger', tabindex: '0',
    'data-doc': 'Debugger: 0–9 invoke a restart · q abort · c continue · Esc back to the input',
    onkeydown: e => {
      if (e.target === value) { if (e.key === 'Enter') { e.preventDefault(); value.blur(); box.focus(); } return; }
      if (/^[0-9]$/.test(e.key)) { e.preventDefault(); choose(Number(e.key)); }
      else if (e.key === 'q' || e.key === 'a') { e.preventDefault(); choose('abort'); }
      else if (e.key === 'c') {
        const restart = d.restarts.find(r => r.name === 'CONTINUE');
        if (restart) { e.preventDefault(); choose(restart.index); }
      } else if (e.key === 'Escape') ui.repl.focus();
    },
  },
  el('div', { class: 'dbg-title' }, el('span', {}, 'Debugger'), presentation(d.type, d.id, 'the condition')),
  el('pre', { class: 'dbg-condition-text' }, d.condition),
  d.note ? el('div', { class: 'dbg-note' }, d.note) : '',
  el('div', { class: 'dbg-heading' }, 'Restarts'),
  el('div', { class: 'dbg-restarts' }, d.restarts.map(r => el('button', {
    class: 'dbg-restart mouse', type: 'button', onclick: () => choose(r.index),
    'data-doc': `Invoke ${r.name} (key ${r.index})`,
  }, el('b', {}, `${r.index}`), el('span', { class: 'dbg-restart-name' }, r.name), el('span', {}, r.report)))),
  el('div', { class: 'dbg-row' }, value,
    el('button', { class: 'btn btn-small', type: 'button', onclick: () => choose('abort'), 'data-doc': 'Abandon the evaluation (q)' }, 'Abort'),
    el('button', {
      class: 'btn btn-small', type: 'button',
      'data-doc': 'Ask the agent about this error (it reads the REPL transcript)',
      onclick: () => insertInComposer(`Explain the error in my Lisp REPL (entry [${entry.id}], ${d.type}) and how to fix it.`),
    }, 'Ask the agent')),
  el('details', { class: 'dbg-backtrace' }, el('summary', {}, `Backtrace · ${d.backtrace.length} frames`),
    el('ol', { class: 'dbg-frames', start: 0 }, d.backtrace.map(frame => el('li', {}, code(frame))))));
  return box;
}

function renderEntry(entry) {
  if (!ui) return;
  const follow = nearBottom();
  const old = ui.transcript.querySelector(`.lisp-entry[data-id="${entry.id}"]`);
  const node = entryNode(entry);
  if (old) old.replaceWith(node); else ui.transcript.append(node);
  if (entry.state === 'debugger' && document.activeElement === ui.repl.input) node.querySelector('.debugger')?.focus({ preventScroll: true });
  if (follow || !old) scrollToEnd();
}

function renderTranscript() {
  if (!ui) return;
  ui.transcript.replaceChildren(
    el('div', { class: 'lisp-herald' },
      el('div', {}, el('b', {}, 'Lisp listener'), ' · the agent\'s own image · SBCL ', el('span', { class: 'faint' }, '(Click a value to inspect it.)')),
      el('div', { class: 'faint' }, 'RET evaluates · Tab completes · M-p/M-n history · C-c C-c interrupts · C-c C-z scratch · M-. definition · C-c C-d d describe')),
    ...[...lisp.entries.values()].map(entryNode));
  scrollToEnd();
}

function info(title, body, color = 'ink') {
  if (!ui) return;
  const node = el('div', { class: 'lisp-info', style: { '--info-color': `var(--${color})`, '--info-on': `var(--on-${color}, var(--paper))` } },
    el('div', { class: 'info-title' }, el('span', {}, title),
      el('button', { class: 'btn btn-small', type: 'button', onclick: () => node.remove(), 'data-doc': 'Dismiss' }, '×')),
    body);
  ui.transcript.append(node);
  scrollToEnd();
}

// ---------- talking to Lisp ----------

async function loadState() {
  const data = await api('/api/lisp/state');
  lisp.package = data.package;
  lisp.busy = data.busy;
  lisp.entries = new Map(data.entries.map(e => [e.id, e]));
  lisp.scratch = data.scratch;
  if (!ui) return;
  ui.saved = data.scratch.text;
  if (ui.scratch.value !== data.scratch.text && !ui.dirty) ui.scratch.value = data.scratch.text;
  renderTranscript();
  updateChrome();
}

async function evaluate(text, { mode = 'eval', source = 'repl', packageName, echo = false } = {}) {
  try {
    const { id } = await api('/api/lisp/eval', { method: 'POST', body: { text, mode, source, package: packageName } });
    if (echo) ui.echoFor = id;
    return id;
  } catch (err) {
    message(err.message);
    return null;
  }
}

function interrupt() {
  api('/api/lisp/interrupt', { method: 'POST' })
    .then(r => message(r.status === 'idle' ? 'Nothing is running.' : r.status === 'aborted' ? 'Aborted.' : 'Interrupted: see the debugger.'))
    .catch(err => message(err.message));
}

async function clearRepl() {
  await api('/api/lisp/clear', { method: 'POST' });
}

function packageFor(editor) {
  return editor === ui.scratch ? (ui.scratch.packageAtPoint() || undefined) : undefined;
}

async function lispComplete(editor, text, cursor) {
  const pkg = packageFor(editor);
  return api('/api/lisp/complete', { params: { text, cursor, ...(pkg ? { package: pkg } : {}) } });
}

function symbolOrAsk(editor) {
  const symbol = editor.symbolAtPoint()?.text;
  if (symbol) return symbol;
  message('No symbol at point.');
  return null;
}

const actions = {
  async describe(editor) {
    const symbol = symbolOrAsk(editor);
    if (!symbol) return;
    const { text } = await api('/api/lisp/describe', { params: { symbol, ...(packageFor(editor) ? { package: packageFor(editor) } : {}) } });
    info(`Describe ${symbol}`, el('pre', { class: 'info-text' }, text));
  },
  async hyperspec(editor) {
    const symbol = symbolOrAsk(editor);
    if (!symbol) return;
    const { text } = await api('/api/lisp/hyperspec', { params: { symbol } });
    info(`HyperSpec: ${symbol}`, el('pre', { class: 'info-text' }, text), 'blue');
  },
  async apropos(editor) {
    const symbol = editor.symbolAtPoint()?.text || editor.selection.text;
    if (!symbol) { message('Put the cursor on a word to search for.'); return; }
    const { text } = await api('/api/lisp/apropos', { params: { query: symbol.replace(/^.*:/, '') } });
    info(`Apropos "${symbol}"`, el('pre', { class: 'info-text' }, text));
  },
  async definition(editor) {
    const symbol = symbolOrAsk(editor);
    if (!symbol) return;
    const { definitions } = await api('/api/lisp/definition', { params: { symbol, ...(packageFor(editor) ? { package: packageFor(editor) } : {}) } });
    if (!definitions.length) { message(`No source location known for ${symbol}.`); return; }
    info(`Definitions of ${symbol}`, el('div', {}, definitions.map(d => el('div', { class: 'definition' },
      el('div', { class: 'definition-head' },
        el('span', { class: 'chip fill-violet' }, d.type),
        el('span', { class: 'definition-file', title: d.file }, `${d.file.replace(/^.*\/(src|ocicl)\//, '$1/')}${d.line ? `:${d.line}` : ''}`),
        d.origin === 'archive'
          ? el('span', { class: 'chip', 'data-doc': 'The source compiled into this image: the file on disk is gone or has changed since' }, 'from the image')
          : '',
        d.snippet ? el('button', {
          class: 'btn btn-small', type: 'button', 'data-doc': 'Append this definition to the scratch buffer to edit it',
          onclick: () => { appendToScratch(d.snippet); showScratch(); },
        }, 'Copy to scratch') : ''),
      d.snippet ? code(d.snippet) : ''))), 'violet');
  },
  async macroexpand(editor, all = false) {
    const form = editor.sexpBeforePoint() || editor.toplevelAtPoint();
    if (!form) { message('No form at point.'); return; }
    try {
      const { expansion } = await api('/api/lisp/macroexpand', { method: 'POST', body: { text: form.text, all, package: packageFor(editor) } });
      info(all ? 'Macroexpand all' : 'Macroexpand 1', el('div', {}, code(form.text), el('div', { class: 'info-arrow' }, '⟹'), code(expansion)), 'orange');
    } catch (err) { message(err.message); }
  },
  async inspectPrompt(editor) {
    const form = editor.selection.text || editor.sexpBeforePoint()?.text;
    const text = window.prompt('Inspect the value of:', form || '*');
    if (!text) return;
    const id = await evaluate(text, { source: editor === ui.scratch ? 'scratch' : 'repl', packageName: packageFor(editor) });
    if (id) ui.inspectAfter = id;
  },
  compileForm(editor) {
    const form = editor.toplevelAtPoint();
    if (!form) { message('No form here.'); return; }
    editor.flash(form.start, form.end);
    evaluate(form.text, { mode: 'compile', source: 'scratch', packageName: packageFor(editor), echo: true });
  },
  evalToplevel(editor) {
    const form = editor.toplevelAtPoint();
    if (!form) { message('No form here.'); return; }
    editor.flash(form.start, form.end);
    evaluate(form.text, { source: editor === ui.scratch ? 'scratch' : 'repl', packageName: packageFor(editor), echo: true });
  },
  evalLast(editor) {
    const form = editor.sexpBeforePoint();
    if (!form) { message('No form before the cursor.'); return; }
    editor.flash(form.start, form.end);
    evaluate(form.text, { source: editor === ui.scratch ? 'scratch' : 'repl', packageName: packageFor(editor), echo: true });
  },
  async compileBuffer() {
    await saveScratch(true);
    evaluate('', { mode: 'compile-file', source: 'scratch', echo: true });
  },
};

const sharedKeys = {
  'C-c C-d d': actions.describe,
  'C-c C-d C-d': actions.describe,
  'C-c C-d h': actions.hyperspec,
  'C-c C-d a': actions.apropos,
  'M-.': actions.definition,
  'C-c RET': editor => actions.macroexpand(editor),
  'C-c M-m': editor => actions.macroexpand(editor, true),
  'C-c I': actions.inspectPrompt,
  'C-x C-e': actions.evalLast,
  'C-c C-k': actions.compileBuffer,
  'C-c M-o': clearRepl,
};

// ---------- the REPL input ----------

const history = storage('lisp-history', []);
let historyIndex = -1;
let draft = '';

function recall(direction) {
  if (!history.length) return;
  if (historyIndex === -1) {
    if (direction > 0) return;
    draft = ui.repl.value;
    historyIndex = history.length;
  }
  const next = historyIndex + direction;
  if (next < 0) return;
  if (next >= history.length) { historyIndex = -1; ui.repl.value = draft; ui.repl.setCursor(draft.length); return; }
  historyIndex = next;
  ui.repl.value = history[next];
  ui.repl.setCursor(history[next].length);
}

function submitRepl(editor) {
  const text = editor.value;
  if (!text.trim()) return true;
  if (lisp.busy) { message('Lisp is busy: C-c C-c interrupts it.'); return true; }
  if (!isComplete(text)) return false;
  if (history[history.length - 1] !== text) history.push(text);
  if (history.length > 500) history.splice(0, history.length - 500);
  store('lisp-history', history);
  historyIndex = -1;
  editor.value = '';
  evaluate(text).then(id => { if (!id) { editor.value = text; editor.setCursor(text.length); } });
  return true;
}

// ---------- the scratch buffer ----------

async function saveScratch(now = false) {
  clearTimeout(ui.saveTimer);
  if (!now) { ui.saveTimer = setTimeout(() => saveScratch(true), 600); return; }
  const text = ui.scratch.value;
  if (text === ui.saved) { ui.dirty = false; updateChrome(); return; }
  try {
    const { version } = await api('/api/lisp/scratch', { method: 'POST', body: { text, base: lisp.scratch.version, client } });
    lisp.scratch.version = version;
    lisp.scratch.text = text;
    ui.saved = text;
    ui.dirty = ui.scratch.value !== text;
    if (ui.dirty) saveScratch();
  } catch (err) {
    if (/changed meanwhile/.test(err.message)) {
      const data = await api('/api/lisp/state');
      showConflict(data.scratch);
    } else message(`Not saved: ${err.message}`);
  }
  updateChrome();
}

function applyRemoteScratch(ev) {
  if (ev.client === client) { lisp.scratch.version = Math.max(lisp.scratch.version, ev.version); return; }
  if (!ui) { lisp.scratch = { ...lisp.scratch, text: ev.text, version: ev.version }; lisp.agentEdited ||= ev.by === 'agent'; return; }
  if (ui.dirty && ui.scratch.value !== ev.text) { showConflict({ text: ev.text, version: ev.version }, ev.by); return; }
  lisp.scratch.text = ev.text;
  lisp.scratch.version = ev.version;
  ui.saved = ev.text;
  ui.scratch.value = ev.text;
  if (ev.by === 'agent') {
    message('The agent updated the scratch buffer.');
    if (activeView() !== 'lisp') lisp.agentEdited = true;
  }
  updateChrome();
}

function showConflict(remote, by = 'someone') {
  ui.conflict.hidden = false;
  ui.conflict.replaceChildren(
    el('span', {}, `${by === 'agent' ? 'The agent' : 'Another page'} changed the scratch buffer while you were typing.`),
    el('button', {
      class: 'btn btn-small', type: 'button', 'data-doc': 'Replace your text with the newer version',
      onclick: () => {
        lisp.scratch = { ...lisp.scratch, ...remote };
        ui.saved = remote.text; ui.scratch.value = remote.text; ui.dirty = false; ui.conflict.hidden = true; updateChrome();
      },
    }, 'Use theirs'),
    el('button', {
      class: 'btn btn-small btn-primary', type: 'button', 'data-doc': 'Keep your text and save it over theirs',
      onclick: () => { lisp.scratch.version = remote.version; ui.conflict.hidden = true; saveScratch(true); },
    }, 'Keep mine'));
}

function appendToScratch(text) {
  const value = ui.scratch.value;
  ui.scratch.replaceRange(value.length, value.length, `${value.endsWith('\n\n') ? '' : value.endsWith('\n') ? '\n' : '\n\n'}${text}\n`);
}

function showScratch() { ui.scratch.focus(); }

// ---------- the echo area: autodoc and messages ----------

let autodoc = null;

async function updateAutodoc(editor, call) {
  if (!call) { autodoc = null; renderAutodoc(); return; }
  const pkg = packageFor(editor);
  try {
    const data = await api('/api/lisp/autodoc', {
      params: { operator: call.operator, ...(call.index !== null ? { index: call.index } : {}), ...(call.keyword ? { keyword: call.keyword } : {}), ...(pkg ? { package: pkg } : {}) },
    });
    autodoc = data.operator ? data : null;
  } catch (err) { autodoc = null; }
  renderAutodoc();
}

function renderAutodoc() {
  if (!ui || ui.echo.classList.contains('message')) return;
  if (!autodoc) { ui.echo.replaceChildren(el('span', { class: 'faint' }, `${lisp.package}> · Tab completes · RET evaluates · C-c C-d d describes`)); return; }
  const parts = autodoc.arglist.length
    ? autodoc.arglist.map((arg, i) => el('span', { class: i === autodoc.current ? 'ad-current' : arg.startsWith('&') ? 'ad-lambda' : '' }, arg))
    : [el('span', { class: 'faint' }, autodoc.syntax || '')];
  const spaced = parts.flatMap((p, i) => (i ? [' ', p] : [p]));
  ui.echo.replaceChildren(
    el('span', { class: 'ad-call' }, '(', el('b', { class: `ad-op ${autodoc.kind}` }, autodoc.operator), autodoc.arglist.length ? ' ' : '', ...spaced, ')'),
    autodoc.doc ? el('span', { class: 'ad-doc' }, ` — ${autodoc.doc}`) : '');
}

// ---------- chrome ----------

function updateChrome() {
  if (!ui) return;
  ui.prompt.textContent = `${lisp.package}>`;
  const debugging = [...lisp.entries.values()].some(e => e.state === 'debugger');
  ui.replStatus.textContent = debugging ? 'debugger' : lisp.busy ? 'running' : 'ready';
  ui.replStatus.className = `chip ${debugging ? 'fill-red' : lisp.busy ? 'fill-orange' : 'fill-green'}`;
  ui.interruptButton.hidden = !lisp.busy;
  ui.scratchInfo.textContent = `scratch.lisp · v${lisp.scratch.version}`;
  ui.scratchInfo.title = lisp.scratch.path;
  ui.saveState.textContent = ui.dirty ? 'editing' : 'saved';
  ui.saveState.className = `chip ${ui.dirty ? 'fill-yellow' : 'fill-paper'}`;
}

function keyHelp() {
  const rows = [
    ['Tab', 'indent the line, or complete: file names in strings, the call\'s keyword arguments, symbols (prefix, m-v-b, flex)'],
    ['C-M-i', 'complete at point'], ['M-/', 'expand the word from the buffers, REPL history and transcript; again for the next'],
    ['RET', 'REPL: evaluate a complete input (Shift-RET: newline)'],
    ['M-p / M-n, ↑ ↓', 'REPL: previous / next input'], ['C-c C-c', 'scratch: compile the toplevel form · REPL: interrupt'],
    ['C-x C-e', 'evaluate the form before the cursor'], ['C-M-x', 'scratch: evaluate the toplevel form'],
    ['C-c C-k', 'compile and load the scratch buffer'], ['C-c C-z', 'switch between scratch and REPL'],
    ['C-c C-d d', 'describe the symbol at point'], ['C-c C-d h', 'HyperSpec entry for it'], ['C-c C-d a', 'apropos'],
    ['M-.', 'find its definition (source)'], ['C-c RET / C-c M-m', 'macroexpand-1 / macroexpand-all'],
    ['C-c I', 'inspect the value of an expression'], ['C-c M-o', 'clear the REPL'],
    ['Click a value', 'inspect it (Inspect panel) · Alt-click: insert a reference'],
    ['Debugger', '0–9 invoke a restart · q abort · c continue'],
  ];
  info('Keys', el('table', { class: 'keys' }, rows.map(([k, d]) => el('tr', {}, el('td', {}, el('kbd', {}, k)), el('td', {}, d)))));
}

// ---------- the view ----------

function mount(container) {
  const transcript = el('div', { class: 'repl-transcript', 'aria-live': 'polite' });
  const prompt = el('span', { class: 'lisp-prompt repl-prompt' }, `${lisp.package}>`);
  const echo = el('div', { class: 'echo-area', 'data-doc': 'Echo area: the argument list of the call at the cursor, and messages' });
  const conflict = el('div', { class: 'scratch-conflict', hidden: true });
  const replStatus = el('span', { class: 'chip fill-green' }, 'ready');
  const saveState = el('span', { class: 'chip fill-paper' }, 'saved');
  const scratchInfo = el('span', { class: 'subpane-info' });
  const interruptButton = el('button', { class: 'btn btn-small btn-danger', type: 'button', hidden: true, onclick: interrupt, 'data-doc': 'Break into the evaluation (C-c C-c)' }, 'Interrupt');
  const button = (label, doc, onclick, cls = '') => el('button', { class: `btn btn-small ${cls}`, type: 'button', 'data-doc': doc, onclick }, label);

  const scratchHost = el('div', { class: 'scratch-host' });
  const replHost = el('div', { class: 'repl-input-host' });
  container.append(el('div', { class: 'lisp-split' },
    el('section', { class: 'subpane scratch-pane', 'aria-label': 'Scratch buffer' },
      el('div', { class: 'subpane-title' }, el('span', { class: 'subpane-name' }, 'Scratch'), scratchInfo, saveState,
        el('span', { class: 'spacer' }),
        button('Compile form', 'Compile the toplevel form at the cursor (C-c C-c)', () => actions.compileForm(ui.scratch)),
        button('Eval last', 'Evaluate the form before the cursor (C-x C-e)', () => actions.evalLast(ui.scratch)),
        button('Load buffer', 'Compile and load the whole buffer (C-c C-k)', () => actions.compileBuffer()),
        copilotBox(() => ui.scratch.focus()),
        button('Ask the agent', 'Ask the agent to review this buffer (or the selected lines)', () => {
          const { start, end, text } = ui.scratch.selection;
          insertInComposer(text.trim()
            ? `Review lines ${ui.scratch.lineOf(start)}–${ui.scratch.lineOf(end)} of my Lisp scratch buffer.`
            : 'Review the code in my Lisp scratch buffer.');
        }, 'btn-primary')),
      conflict, scratchHost),
    el('section', { class: 'subpane repl-pane', 'aria-label': 'REPL' },
      el('div', { class: 'subpane-title' }, el('span', { class: 'subpane-name' }, 'REPL'), replStatus,
        el('span', { class: 'spacer' }), interruptButton,
        button('Clear', 'Clear the REPL transcript (C-c M-o)', clearRepl),
        button('Keys', 'The key bindings', () => keyHelp())),
      transcript,
      el('div', { class: 'repl-input' }, prompt, replHost))),
  echo);

  ui = { container, transcript, prompt, echo, conflict, replStatus, saveState, scratchInfo, interruptButton, dirty: false, saved: lisp.scratch.text };

  ui.scratch = createLispEditor(scratchHost, {
    className: 'scratch-editor',
    value: lisp.scratch.text,
    doc: 'Scratch buffer: Lisp you and the agent share · C-c C-c compile form · C-c C-k load buffer · C-c Tab copilot',
    keymap: {
      ...sharedKeys,
      'C-c C-c': actions.compileForm,
      'C-M-x': actions.evalToplevel,
      'C-c C-z': () => ui.repl.focus(),
      'C-x C-s': () => saveScratch(true).then(() => message('Saved.')),
    },
    complete: (text, cursor) => lispComplete(ui.scratch, text, cursor),
    ...copilotOptions(() => 'scratch.lisp'),
    dabbrevText: () => [ui.repl.value, ...[...history].reverse(), ui.transcript.textContent].join('\n'),
    onChange: () => { ui.dirty = true; updateChrome(); saveScratch(); },
    onContext: call => updateAutodoc(ui.scratch, call),
    onMessage: text => (text ? message(text, 2500) : null),
  });

  ui.repl = createLispEditor(replHost, {
    className: 'repl-editor',
    placeholder: '(+ 1 2)',
    doc: 'REPL input: RET evaluates · M-p/M-n history · C-c C-c interrupts',
    keymap: {
      ...sharedKeys,
      'C-c C-c': interrupt,
      'C-c C-z': () => ui.scratch.focus(),
      'M-p': () => recall(-1),
      'M-n': () => recall(1),
    },
    complete: (text, cursor) => lispComplete(ui.repl, text, cursor),
    // In the REPL only C-c Tab asks: a suggestion per pause would get in
    // the way of quick evaluation.
    ...copilotOptions(() => 'repl.lisp', { auto: false }),
    dabbrevText: () => [ui.scratch.value, ...[...history].reverse(), ui.transcript.textContent].join('\n'),
    onEnter: submitRepl,
    onKey: (editor, e) => {
      if (e.ctrlKey || e.altKey || e.metaKey || e.shiftKey) return false;
      const { value, cursor } = editor;
      if (e.key === 'ArrowUp' && !value.slice(0, cursor).includes('\n') && (historyIndex !== -1 || !value)) { recall(-1); return true; }
      if (e.key === 'ArrowDown' && historyIndex !== -1 && !value.slice(cursor).includes('\n')) { recall(1); return true; }
      return false;
    },
    onContext: call => updateAutodoc(ui.repl, call),
    onMessage: text => (text ? message(text, 2500) : null),
  });

  lisp.mounted = true;
  renderTranscript();
  updateChrome();
  renderAutodoc();
  loadState().catch(err => message(`Could not load the Lisp REPL: ${err.message}`));
}

// ---------- server events ----------

on('lisp-entry', ev => {
  const entry = ev.entry;
  lisp.entries.set(entry.id, entry);
  if (lisp.entries.size > 300) lisp.entries.delete(lisp.entries.keys().next().value);
  lisp.package = ev.package;
  lisp.busy = ev.busy;
  if (!ui) return;
  renderEntry(entry);
  updateChrome();
  if (entry.state === 'done' || entry.state === 'aborted') {
    if (ui.echoFor === entry.id) {
      ui.echoFor = null;
      message(entry.state === 'aborted' ? '; Evaluation aborted'
        : entry.values.length ? `⇒ ${entry.values.map(v => v.text.split('\n')[0]).join(', ').slice(0, 300)}` : '; No values');
    }
    if (ui.inspectAfter === entry.id) {
      ui.inspectAfter = null;
      if (entry.values[0]) inspect(entry.values[0].id);
    }
  }
});

on('lisp-output', ev => {
  const entry = lisp.entries.get(ev.id);
  if (entry) entry.output += ev.text;
  const node = ui?.transcript.querySelector(`.lisp-entry[data-id="${ev.id}"] .lisp-output`);
  if (node) {
    const follow = nearBottom();
    node.hidden = false;
    node.append(ev.text);
    if (follow) scrollToEnd();
  }
});

on('lisp-scratch', applyRemoteScratch);
on('lisp-clear', () => {
  for (const [id, entry] of lisp.entries) if (entry.state !== 'running' && entry.state !== 'debugger') lisp.entries.delete(id);
  renderTranscript();
});
on('state', () => { if (ui) loadState().catch(() => {}); });

// ---------- the inspector panel ----------

const inspected = [];      // a stack of inspector views, newest last

async function inspect(id) {
  try {
    const data = await api('/api/lisp/inspect', { params: { id } });
    inspected.push(data);
    if (inspected.length > 50) inspected.shift();
    showPanel('inspector');
  } catch (err) { toast(err.message, 'red'); }
}

registerPanel({
  id: 'inspector', title: 'Inspect', color: 'cyan', order: 15,
  doc: 'The Lisp inspector: click a value in the Lisp tab to look inside it',
  events: [],
  render(target) {
    const top = inspected[inspected.length - 1];
    if (!top) {
      target.replaceChildren(el('div', { class: 'panel' }, el('div', { class: 'empty' },
        'Nothing inspected yet. In the Lisp tab, click any printed value (or press C-c I) to look inside it here.')));
      return;
    }
    const part = p => el('tr', {},
      el('th', {}, p.label),
      el('td', {}, p.id ? presentation(p.text, p.id) : el('span', { class: 'inspector-text' }, p.text)));
    target.replaceChildren(el('div', { class: 'panel inspector' },
      el('div', { class: 'inspector-head' },
        el('div', { class: 'inspector-title' }, presentation(top.title, top.id, top.type)),
        el('span', { class: 'chip fill-cyan' }, top.type)),
      el('div', { class: 'inspector-actions' },
        el('button', { class: 'btn btn-small', type: 'button', disabled: inspected.length < 2, onclick: () => { inspected.pop(); showPanel('inspector'); }, 'data-doc': 'Back to the previous object' }, '◀ Back'),
        el('button', { class: 'btn btn-small', type: 'button', onclick: () => { inspected.pop(); inspect(top.id); }, 'data-doc': 'Inspect it again (it may have changed)' }, '↻ Refresh'),
        el('button', {
          class: 'btn btn-small', type: 'button', 'data-doc': `Put ${reference(top.id)} in the REPL input`,
          onclick: () => { showView('lisp'); ui?.repl.insert(reference(top.id)); ui?.repl.focus(); },
        }, '→ REPL'),
        el('span', { class: 'faint' }, `${inspected.length} deep`)),
      top.parts.length ? el('table', { class: 'inspector-parts' }, top.parts.map(part)) : el('div', { class: 'empty' }, 'No parts.')));
  },
});

// ---------- registration ----------

registerView({
  id: 'lisp', title: 'Lisp', color: 'violet', order: 10,
  doc: 'A Common Lisp REPL on the agent\'s own image, and a scratch buffer shared with the agent (Alt-L)',
  badge: () => {
    const running = [...lisp.entries.values()].some(e => e.state === 'debugger') ? '!' : lisp.busy ? '●' : '';
    return running || (lisp.agentEdited ? '✎' : '');
  },
  mount,
  show: () => {
    lisp.agentEdited = false;
    setTimeout(() => ui?.repl.focus(), 0);
  },
});

/** For plugins: CLAgent.lisp.evaluate("(+ 1 2)"), .inspect(id), .scratch(). */
export const lispApi = {
  evaluate: (text, options) => evaluate(text, options),
  inspect,
  scratch: () => ui?.scratch.value ?? lisp.scratch.text,
  insert: text => { showView('lisp'); ui?.repl.insert(text); ui?.repl.focus(); },
};
