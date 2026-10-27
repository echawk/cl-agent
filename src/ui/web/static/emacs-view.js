// emacs-view.js -- an Emacs frame in a pane: cl-agent's Emacs daemon
// (emacs.lisp) shows a frame (emacsclient -t) in a terminal, drawn here by
// slt's client like the Terminal tab's (terminal.js).  The Code tab's
// editor is the "code" frame, the Lisp tab's scratch pane the "lisp" one.
//
//   createEmacsView(host, {role, message, onOpen})   onOpen: a new frame opened
//     .ensure()   the frame, started (and Emacs with it) if need be
//     .focus()    keys to Emacs
//     .opened     whether a frame is showing
//
// A frame closed in Emacs (C-x 5 0, or Emacs exiting) leaves a note with a
// Reopen button.  The page's light or dark goes to Emacs (its faces).

import { on, el, api } from './core.js';
import { mountTerminal, sizeFor } from './terminal.js';

const lightOrDark = () => (getComputedStyle(document.documentElement).colorScheme.includes('dark') ? 'dark' : 'light');

let emacs = { state: 'unknown', available: true };
const loadState = () => api('/api/emacs').then(data => { emacs = data; }).catch(() => {});
on('emacs-state', ev => { emacs = ev; });
on('theme', () => setTimeout(() => {
  if (emacs.state === 'running') api('/api/emacs/background', { method: 'POST', body: { mode: lightOrDark() } }).catch(() => {});
}, 0));
loadState();

/** Whether Emacs is installed (GET /api/emacs). */
export const emacsAvailable = async () => { await loadState(); return emacs.available !== false; };

export function createEmacsView(host, { role, message = () => {}, onOpen = () => {} }) {
  let terminal = null;
  let starting = null;
  const screen = el('div', { class: 'emacs-screen' });
  const note = el('div', { class: 'emacs-note', hidden: true });
  host.append(screen, note);

  function showNote(text, button) {
    note.replaceChildren(el('p', {}, text), button || '');
    note.hidden = false;
  }

  async function start() {
    showNote(emacs.state === 'running' ? 'Opening an Emacs frame…' : 'Starting Emacs…');
    api('/api/emacs/background', { method: 'POST', body: { mode: lightOrDark() } }).catch(() => {});
    let entry;
    try {
      entry = await api('/api/emacs/frame', { method: 'POST', body: { role, ...sizeFor(host) } });
    } catch (err) {
      showNote(`Emacs did not start: ${err.message}`, el('button', { class: 'btn', type: 'button', onclick: () => view.ensure() }, 'Try again'));
      message(err.message);
      throw err;
    }
    terminal?.dispose();
    screen.replaceChildren();
    terminal = await mountTerminal(screen, entry.url);
    terminal.addEventListener('exit', () => {
      terminal?.dispose();
      terminal = null;
      screen.replaceChildren();
      showNote('This Emacs frame was closed.', el('button', { class: 'btn', type: 'button', onclick: () => view.ensure().then(() => view.focus()) }, 'Reopen'));
    });
    note.hidden = true;
    // A new frame shows Emacs's last buffer: the pane puts its own back.
    try { await onOpen(); } catch (err) { message(err.message); }
    return terminal;
  }

  const view = {
    get opened() { return !!terminal; },
    /** The frame's terminal, opened if need be (once at a time). */
    ensure() {
      if (terminal) return Promise.resolve(terminal);
      starting ??= start().finally(() => { starting = null; });
      return starting;
    },
    focus() { if (terminal) setTimeout(() => { terminal.fit(); terminal.focus(); }, 0); },
    fit() { terminal?.fit(); },
  };
  new ResizeObserver(() => terminal?.fit()).observe(host);
  return view;
}
