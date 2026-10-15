// forms.js -- the listener reads Lisp: a form typed at the main prompt is
// evaluated in the agent's image, as at a Genera listener, and its result
// appears in the transcript as a presentation (click: inspect).  Prose goes
// to the agent and /name runs a command; the prompt says which before you
// press Enter (composer.js).  See docs/ui-ux-review.md, section 9.
//
//   classify(text)   'command' | 'form' | 'open-form' (unfinished) | 'ask' | 'empty'
//   evaluate(text)   POST /api/lisp/eval with source "listener"
//
// The rule is syntactic: input that is nothing but Lisp forms at top level
// -- (...), 'x, `x, #'f, #(...), #\c, #+feature x -- is evaluated;
// "(optional) fix the tests" has bare words after its form, so it is a
// request.  A leading comma forces evaluation (",*features*").  The
// entries are the Lisp REPL's own (one image, one history): the Lisp tab
// shows them too, and the agent reads them with lisp-scratch.

import { state, on, emit, api, el, live, storage, store } from './core.js';
import { lispEntryNode } from './lisp.js';
import { turnExtras, scrollToLatest } from './render.js';
import { insert as insertInComposer } from './composer.js';
import { classify } from './lisp-read.js';

export { classify };

/** The text to evaluate for TEXT classified as a form. */
const formText = text => text.trimStart().replace(/^,/, '');

// ---------- the package the prompt shows ----------

export const lispState = { package: 'CL-AGENT', loaded: false };

async function loadLispState() {
  try {
    const data = await api('/api/lisp/state');
    lispState.package = data.package;
    lispState.loaded = true;
    for (const entry of data.entries) entries.set(entry.id, entry);
    if (Object.keys(placed).length) emit('rerender');
  } catch (err) { /* the server is starting: the next event brings it */ }
}

// ---------- listener entries ----------

const entries = new Map();                   // id -> entry, every REPL entry seen
const key = () => `listener-forms.${live.id || 'main'}`;
let placed = storage(key(), {});             // id -> the turn it was evaluated in

const ctx = {
  insert: text => insertInComposer(text),
  focus: () => document.getElementById('input')?.focus(),
  where: 'the prompt',
};

const nodeFor = entry => el('div', { class: 'listener-form', dataset: { lisp: entry.id } }, lispEntryNode(entry, ctx));

function place(turnSection) {
  for (const [id, turn] of Object.entries(placed)) {
    const entry = entries.get(+id);
    if (entry) turnSection(turn).append(nodeFor(entry));
  }
}
turnExtras.push(place);

/** Evaluate TEXT (classified 'form') in the image; its entry shows here. */
export async function evaluate(text) {
  const { id } = await api('/api/lisp/eval', { method: 'POST', body: { text: formText(text), source: 'listener' } });
  placed[id] = state.turn || 0;
  const ids = Object.keys(placed);
  if (ids.length > 200) delete placed[ids[0]];
  store(key(), placed);
  if (!entries.has(id)) entries.set(id, { id, input: formText(text), package: lispState.package, source: 'listener', mode: 'eval', state: 'running', output: '', notes: [], values: [], elapsed: 0 });
  emit('rerender');
  scrollToLatest();
  return id;
}

/** Esc at the prompt: break into a form evaluating here.  True if one was. */
export function interruptForm() {
  const running = [...entries.values()].some(e => e.id in placed && e.state === 'running');
  if (running) api('/api/lisp/interrupt', { method: 'POST' }).catch(() => {});
  return running;
}

on('lisp-entry', ev => {
  entries.set(ev.entry.id, ev.entry);
  if (ev.package) lispState.package = ev.package;
  if (!(ev.entry.id in placed)) return;
  const node = document.querySelector(`#listener .listener-form[data-lisp="${ev.entry.id}"]`);
  if (node) {
    node.replaceWith(nodeFor(ev.entry));
    if (ev.entry.state === 'debugger') document.querySelector(`#listener .listener-form[data-lisp="${ev.entry.id}"] .debugger`)?.focus({ preventScroll: true });
    scrollToLatest();
  }
});

on('lisp-output', ev => {
  const entry = entries.get(ev.id);
  if (!entry || !(ev.id in placed)) return;
  const node = document.querySelector(`#listener .listener-form[data-lisp="${ev.id}"] .lisp-output`);
  if (node) { node.hidden = false; node.append(ev.text); }
});

on('lisp-clear', () => {
  for (const [id, entry] of entries) if (entry.state !== 'running' && entry.state !== 'debugger') entries.delete(id);
});

on('live-switch', () => { placed = storage(key(), {}); });

loadLispState();
