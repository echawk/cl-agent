// composer.js -- the input line: sending, the prompt, queued messages,
// abort, history, and tab completion.
//
// It is a Genera-style listener prompt (forms.js): a Lisp form is
// evaluated in the image, /name runs a command, anything else is a request
// to the agent.  The prompt label and the send button say which, as you
// type: CL-AGENT> / Command: / (C n), and Eval / Run / Ask.  An unfinished
// form takes Enter as a newline; Alt-Enter always asks the agent.
//
// Completion asks client completers first (CLAgent.registerCompleter),
// then the server (GET /api/complete, see completion.lisp).  Tab inserts
// a unique match or the longest common prefix and opens the possibilities
// menu; Tab / Shift-Tab / ↑ / ↓ move through it, Enter or Tab on a
// selection accepts, Esc closes.  Typing "/" opens the command menu live.

import {
  state, on, el, api, send, interrupt, clientCommands, completers, storage, store,
} from './core.js';
import { createMenu, commonPrefix, menuStep, menuCancel } from './menu.js';
import { classify, evaluate as evaluateForm, interruptForm, lispState } from './forms.js';

const $ = id => document.getElementById(id);
let input, menu;

// ---------- prompt, queue and buttons ----------

function busy() { return state.thinking || state.planning; }

const MODES = {
  command: { label: 'Command:', button: 'Run ⏎', doc: 'Run this command (Enter)', aria: 'Command' },
  form: { button: 'λ Eval ⏎', doc: 'Evaluate this form in the agent\'s image (Enter) · Alt-Enter: ask the agent about it instead', aria: 'Lisp form' },
  ask: { button: 'Ask ⏎', doc: 'Ask the agent (Enter)', aria: 'Request to the agent' },
};

function inputMode() {
  const kind = classify(input.value);
  return kind === 'open-form' ? 'form' : kind;
}

function updatePrompt() {
  const prompt = $('prompt');
  const mode = inputMode();
  // Empty, it is the environment's prompt; what you type says what it becomes.
  prompt.textContent = mode === 'command' ? MODES.command.label
    : mode === 'form' || mode === 'empty' ? `${lispState.package}>` : `(C${(state.turn || 0) + 1})`;
  prompt.classList.toggle('command', mode === 'command');
  prompt.classList.toggle('form', mode === 'form' || mode === 'empty');
  input.setAttribute('aria-label', (MODES[mode] || MODES.ask).aria);
  updateButtons();
}

function updateButtons() {
  const mode = inputMode() === 'empty' ? 'ask' : inputMode();
  $('abort').hidden = !busy();
  const queue = mode === 'ask' && busy();
  $('send').textContent = queue ? 'Queue ⏎' : MODES[mode].button;
  $('send').classList.toggle('btn-ask', mode === 'ask');
  $('send').dataset.doc = queue
    ? 'The agent is busy: your message runs at its next safe point (Enter)'
    : MODES[mode].doc;
}

function renderQueue() {
  $('queue').replaceChildren(...(state.queued || []).map(text =>
    el('div', { class: 'queue-item', title: text, 'data-doc': 'Waiting for the running turn to reach a safe point' }, text)));
}

function autosize() {
  input.style.height = 'auto';
  input.style.height = `${Math.min(input.scrollHeight, window.innerHeight * 0.4)}px`;
}

// ---------- history ----------

const history = storage('history', []);
let historyIndex = -1;
let draft = '';

function remember(text) {
  if (history[history.length - 1] !== text) history.push(text);
  if (history.length > 300) history.splice(0, history.length - 300);
  store('history', history);
  historyIndex = -1;
}

function recall(direction) {
  if (!history.length) return false;
  if (historyIndex === -1) {
    if (direction > 0) return false;
    draft = input.value;
    historyIndex = history.length;
  }
  const next = historyIndex + direction;
  if (next < 0) return true;
  if (next >= history.length) {
    historyIndex = -1;
    setInput(draft);
    return true;
  }
  historyIndex = next;
  setInput(history[next]);
  return true;
}

function setInput(text, caret = text.length) {
  input.value = text;
  input.setSelectionRange(caret, caret);
  autosize();
  updatePrompt();
  try { sessionStorage.setItem('cl-agent.draft', input.value); } catch (err) { /* ignore */ }
}

/** Put TEXT in the input (replacing it), focused; used by panels and plugins. */
export function insert(text) {
  hideMenu();
  setInput(text);
  input.focus();
}

// ---------- sending ----------

async function submit({ ask = false } = {}) {
  const text = input.value.trim();
  if (!text) return;
  remember(text);
  hideMenu();
  if (!ask && classify(text) === 'form') {
    setInput('');
    try { await evaluateForm(text); } catch (err) {
      setInput(text);
      window.CLAgent?.toast(`Not evaluated: ${err.message}`, 'red');
    }
    return;
  }
  const match = text.match(/^\/(\S+)\s*([\s\S]*)$/);
  const local = match && clientCommands.get(match[1]);
  setInput('');
  if (local) {
    try { await local.run(match[2]); } catch (err) { window.CLAgent?.toast(String(err.message || err), 'red'); }
    return;
  }
  try {
    const { status } = await send(text);
    if (status === 'queued') window.CLAgent?.toast('Queued: the agent will read it at its next safe point.', 'yellow');
  } catch (err) {
    setInput(text);
    window.CLAgent?.toast(`Not sent: ${err.message}`, 'red');
  }
}

// ---------- completion ----------

let requestNumber = 0;

function clientCommandCandidates(token) {
  return [...clientCommands].filter(([name]) => `/${name}`.startsWith(token))
    .map(([name, command]) => ({ value: `/${name}`, display: `/${name}`, doc: command.doc, kind: 'command' }));
}

async function fetchCompletions(text, cursor) {
  for (const completer of completers) {
    const result = await completer(text, cursor);
    if (result?.candidates?.length) return result;
  }
  const result = await api('/api/complete', { params: { text, cursor } });
  // Commands registered in the browser complete alongside the server's.
  if (text.startsWith('/') && !text.slice(0, cursor).includes(' ')) {
    const known = new Set(result.candidates.map(c => c.value));
    const extra = clientCommandCandidates(text.slice(0, cursor)).filter(c => !known.has(c.value));
    result.candidates = [...result.candidates, ...extra].sort((a, b) => a.value.localeCompare(b.value));
    result.start = 0;
    result.end = cursor;
    result.token = text.slice(0, cursor);
  }
  result.common = commonPrefix(result.candidates.map(c => c.value));
  return result;
}

function replaceRange(start, end, text) {
  const value = input.value;
  setInput(value.slice(0, start) + text + value.slice(end), start + text.length);
}

function accept(candidate, result) {
  const suffix = candidate.kind === 'dir' || candidate.kind === 'json' ? '' : ' ';
  const after = input.value.slice(result.end);
  replaceRange(result.start, result.end, candidate.value + (after.startsWith(' ') ? '' : suffix));
  hideMenu();
  // A finished command name usually has arguments worth completing next.
  if (candidate.kind === 'command' && suffix) complete({ quiet: true });
}

export async function complete({ quiet = false, live = false } = {}) {
  const text = input.value;
  const cursor = input.selectionStart;
  const number = ++requestNumber;
  let result;
  try { result = await fetchCompletions(text, cursor); } catch (err) { return; }
  if (number !== requestNumber || input.value !== text) return;   // stale
  const { candidates } = result;
  if (!candidates.length) {
    hideMenu();
    if (!quiet && !live) window.CLAgent?.mousedoc('No completions.');
    return;
  }
  if (live) { showMenu(result, -1); return; }
  if (candidates.length === 1) { accept(candidates[0], result); return; }
  if (result.common.length > result.token.length) {
    replaceRange(result.start, result.end, result.common);
    result.end = result.start + result.common.length;
    result.token = result.common;
  }
  if (!quiet || candidates.length <= 40) showMenu(result, 0);
}

function showMenu(result, index) { menu.show(result, index); }
function moveSelection(delta) { menu.move(delta); }
function hideMenu() { menu?.hide(); }

// ---------- keys ----------

function caretOnFirstLine() { return !input.value.slice(0, input.selectionStart).includes('\n'); }
function caretOnLastLine() { return !input.value.slice(input.selectionEnd).includes('\n'); }

function onKeyDown(e) {
  const menuState = menu.state;
  if (menuState) {
    const step = menuStep(e);
    if (step) { e.preventDefault(); moveSelection(step); return; }
    if (menuCancel(e)) { e.preventDefault(); hideMenu(); return; }
    if ((e.key === 'Enter' || e.key === 'ArrowRight') && menuState.index >= 0 && !e.shiftKey) {
      e.preventDefault();
      accept(menuState.result.candidates[menuState.index], menuState.result);
      return;
    }
  }
  if (e.key === 'Tab' && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) {
    e.preventDefault();
    complete();
    return;
  }
  if (e.key === 'Enter' && e.altKey && !e.isComposing) {
    e.preventDefault();
    submit({ ask: true });
    return;
  }
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
    // An unfinished form: Enter continues it on the next line.
    if (classify(input.value) === 'open-form' && input.selectionStart === input.value.length) return;
    e.preventDefault();
    submit();
    return;
  }
  if (e.key === 'Escape') {
    e.preventDefault();
    if (busy()) interrupt();
    else interruptForm();
    return;
  }
  if (e.key === 'ArrowUp' && caretOnFirstLine() && !e.shiftKey) {
    if (recall(-1)) e.preventDefault();
  } else if (e.key === 'ArrowDown' && caretOnLastLine() && !e.shiftKey && historyIndex !== -1) {
    if (recall(1)) e.preventDefault();
  }
}

function onInput() {
  autosize();
  updatePrompt();
  historyIndex = -1;
  try { sessionStorage.setItem('cl-agent.draft', input.value); } catch (err) { /* ignore */ }
  const before = input.value.slice(0, input.selectionStart);
  if (/^\/\S*$/.test(before)) complete({ live: true });
  else if (menu.state) hideMenu();
}

export function install() {
  input = $('input');
  menu = createMenu($('completions'), { onAccept: accept });
  input.addEventListener('keydown', onKeyDown);
  input.addEventListener('input', onInput);
  input.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== input) hideMenu(); }, 150));
  $('composer').addEventListener('submit', e => { e.preventDefault(); submit(); });
  $('abort').addEventListener('click', () => interrupt());
  try {
    const saved = sessionStorage.getItem('cl-agent.draft');
    if (saved) setInput(saved);
  } catch (err) { /* ignore */ }
  for (const type of ['status', 'state', 'message', 'lisp-entry']) {
    on(type, () => { updatePrompt(); updateButtons(); renderQueue(); });
  }
  updatePrompt();
  updateButtons();
  input.focus();
}
