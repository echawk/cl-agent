// lem-view.js -- Lem's own view of itself: Lem's web frontend, in an
// iframe, showing the hosted Lem (server side: lem/display.lisp).  There is
// one Lem and one view of it.  The Code tab's editor and the Lisp tab's
// scratch buffer each have a *slot* (createLemView); the one frame lies over
// the slot that asked for it last, wherever that slot is laid out, and hides
// when that slot is not on screen.  (Moving an iframe in the DOM would
// reload it, so it is never moved: it is positioned.)  One connection, one
// size, no frame racing another for Lem's window -- each tab still puts its
// own buffer in Lem's window when it is shown.  docs/ui-ux-review.md, 16.
//
// Lem looks like the page: its colours are a Lem theme made from the
// page's theme tokens, sent again whenever the theme changes; its font and
// size are the page's; its chrome takes a few colours as --cl-* variables.
// A view survives what used to leave it blank: it is measured again when
// the page's layout changes, rebuilt when the server restarted (a new
// display port), retried while Lem starts, and says "Starting Lem..."
// until Lem's client has logged in.

import { on, el, api, state } from './core.js';

const TOKENS = ['paper', 'paper-2', 'paper-3', 'ink', 'ink-2', 'ink-3', 'rule', 'rule-soft', 'select', 'code-inline',
  'red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'violet', 'pink', 'on-yellow', 'on-pink', 'title-bg', 'title-fg',
  'shadow-color', 'syn-comment', 'syn-string', 'syn-number', 'syn-keyword', 'syn-operator', 'syn-def', 'syn-constant', 'syn-special'];

function pageColors() {
  const probe = el('span', { hidden: true });
  document.body.append(probe);
  const colors = {};
  for (const name of TOKENS) {
    probe.style.color = '';
    probe.style.color = `var(--${name})`;
    const rgb = getComputedStyle(probe).color.match(/[\d.]+/g);
    if (rgb && rgb.length >= 3) colors[name] = '#' + rgb.slice(0, 3).map(v => Math.round(+v).toString(16).padStart(2, '0')).join('');
  }
  probe.remove();
  return colors;
}

const chromeVars = colors => ({ paper: colors.paper, rule: colors.rule, 'rule-soft': colors['rule-soft'], shadow: colors['shadow-color'] });

/** Give Lem the page's colours (the theme, and the view's chrome). */
function pushTheme(onError) {
  const colors = pageColors();
  shared.frame?.contentWindow?.postMessage({ type: 'cl-agent-style', vars: chromeVars(colors) }, '*');
  // Light or dark by the theme's color-scheme: "mono" and patches' themes too.
  const mode = /dark/.test(getComputedStyle(document.documentElement).colorScheme) ? 'dark' : 'light';
  return api('/api/lem/theme', { method: 'POST', body: { mode, colors } }).catch(err => onError?.(`Lem theme: ${err.message}`));
}

async function frameURL() {
  const style = getComputedStyle(document.documentElement);
  const font = style.getPropertyValue('--font').trim() || 'monospace';
  const size = Math.round(parseFloat(style.getPropertyValue('--font-size')) || 14);
  const { url } = await api('/api/lem/display', { params: { font, size } });
  const chrome = Object.entries(chromeVars(pageColors())).filter(([, v]) => v);
  return url + '&' + new URLSearchParams(chrome);
}

/** A slot for the Lem view in HOST (an element): {ensure, remeasure, focus,
drop, frame}.  WANTED says whether it should show Lem now (its tab in Lem
mode); MESSAGE reports trouble.  ensure() brings the one frame here. */
export function createLemView(host, { wanted = () => true, message = () => {} } = {}) {
  const slot = { host, wanted, message };
  if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => { if (shared.slot === slot) place(); }).observe(host);
  const ensure = () => { shared.slot = slot; return ensureFrame().then(frame => { place(); return frame; }); };
  return { ensure, remeasure, focus, drop, get frame() { return shared.slot === slot ? shared.frame : null; } };
}

// ---------- the one frame ----------

const shared = { frame: null, instance: null, pending: null, attempt: 0, slot: null, starting: false, startTimer: 0, resizeTimer: 0, retry: 0 };
const ATTEMPT_MS = 5000;   // a request that never settles must not block the view for good

/** Lay the frame over its slot's host, or hide it when that is not on screen. */
function place() {
  const { frame, slot } = shared;
  if (!frame) return;
  for (const host of document.querySelectorAll('.lem-slot-active')) if (host !== slot?.host) host.classList.remove('lem-slot-active', 'starting');
  const rect = slot?.host.getBoundingClientRect();
  const shown = slot && slot.wanted() && rect.width > 20 && rect.height > 20 && slot.host.isConnected;
  if (!shown) { frame.style.visibility = 'hidden'; return; }
  slot.host.classList.add('lem-slot-active');
  slot.host.classList.toggle('starting', shared.starting);
  Object.assign(frame.style, { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  const size = `${Math.round(rect.width)}x${Math.round(rect.height)}`;
  if (frame.dataset.size !== size) { frame.dataset.size = size; remeasure(); }
  frame.style.visibility = shared.starting ? 'hidden' : 'visible';
}

// Lem's client measures itself on its window's resize event, which an
// iframe does not always get when only the page's layout changes: tell it,
// once the size settles.
function remeasure() {
  clearTimeout(shared.resizeTimer);
  shared.resizeTimer = setTimeout(() => {
    const frame = shared.frame;
    if (!frame || frame.style.visibility === 'hidden' && !shared.starting) return;
    frame.contentWindow?.postMessage({ type: 'cl-agent-resize' }, '*');
  }, 120);
}

function started() {
  clearTimeout(shared.startTimer);
  shared.starting = false;
  place();
  remeasure();
}

function drop() {
  shared.frame?.remove();
  shared.frame = null;
  shared.instance = null;
}

function focus() {
  setTimeout(() => { shared.frame?.focus(); shared.frame?.contentWindow?.focus(); }, 0);
}

function retryLater() {
  clearTimeout(shared.retry);
  shared.retry = setTimeout(() => { if (shared.slot?.wanted() && !shared.frame) ensureFrame().then(place); }, 3000);
}

function ensureFrame() {
  // A restarted server has a new display (another port): this frame is dead.
  if (shared.frame && shared.instance && state.instance && shared.instance !== state.instance) drop();
  if (shared.frame) return Promise.resolve(shared.frame);
  if (!shared.pending) {
    const attempt = ++shared.attempt;
    const work = (async () => {
      const slot = shared.slot;
      try {
        await pushTheme(slot?.message);
        const src = await frameURL();
        // Given up on meanwhile (a later attempt owns the view now).
        if (attempt !== shared.attempt || shared.frame) return shared.frame;
        const frame = el('iframe', { class: 'lem-frame', src, title: 'Lem', allow: 'clipboard-read; clipboard-write' });
        shared.frame = frame;
        shared.instance = state.instance;
        // Lem's client loads its code and font before it draws: the slot
        // says "Starting Lem..." meanwhile.
        shared.starting = true;
        clearTimeout(shared.startTimer);
        shared.startTimer = setTimeout(started, 30000);
        document.body.append(frame);
      } catch (err) {
        slot?.message(`Lem view unavailable: ${err.message}`);
        // Lem may still be starting: try again while the view is wanted.
        retryLater();
      }
      return shared.frame;
    })();
    // A request can hang while the page and server start; give it up and
    // try again rather than leave every later ensure() waiting on it.
    const deadline = new Promise(resolve => setTimeout(() => resolve('late'), ATTEMPT_MS));
    shared.pending = Promise.race([work, deadline]).then(result => {
      shared.pending = null;
      if (result !== 'late') return result;
      shared.attempt += 1;
      retryLater();
      return null;
    });
  }
  return shared.pending;
}

// The slot moves when the page's layout does: the window, the side panes'
// splitter, a tab switch.  A cheap check catches what no event reports.
window.addEventListener('resize', () => place());
setInterval(() => { if (shared.frame) place(); }, 300);

on('state', () => {
  if (!shared.frame) return;
  if (!shared.instance) { shared.instance = state.instance; return; }   // made before the first state
  if (state.instance && shared.instance !== state.instance) {
    drop();
    if (shared.slot?.wanted()) ensureFrame().then(place);
  }
});
on('theme', () => { if (shared.frame) pushTheme(); });
// A new size means new cells: the client measures its font once.
on('font-size', async () => { if (shared.frame) { shared.starting = true; place(); shared.frame.src = await frameURL(); } });
// Lem's client has logged in: it draws now.
on('lem-display', () => { if (shared.frame) started(); });
