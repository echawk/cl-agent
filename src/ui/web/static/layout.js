// layout.js -- the page's layout is the person's to change.  Every region
// can be hidden or shown, the splitters between them dragged (double-click
// one: back to where it was), and Zoom leaves only the tab in front.  What
// is chosen is kept in this browser.
//
//   regions    the side panes (Ctrl-\), the live-session rail, the prompt,
//              the who-line, the Code tab's file list: the title bar's
//              Layout menu shows and hides each
//   zoom       Alt-Z: only the tab in front, edge to edge; Alt-Z again (or
//              the Unzoom button) brings the rest back
//   splitters  side panes | main (main.js), and inside tabs:
//              makeSplitter -- the Code tab's files | editor, the Lisp tab's
//              scratch | REPL
//
// The prompt comes back by itself when something is put there (C-c C-a in
// an editor, Ask buttons) or when / is pressed.

import { el, on, emit, storage, store } from './core.js';
import { openMenu } from './objects.js';

const REGIONS = [
  { id: 'side', label: 'Side panes', doc: 'Agents, Inspect, Activity, Tools, UI (Ctrl-\\)' },
  { id: 'rail', label: 'Live-session rail', doc: 'The tabs down the left, one per live session' },
  { id: 'composer', label: 'Prompt', doc: 'The main prompt; it comes back when something is put there, or with /' },
  { id: 'wholine', label: 'Who-line', doc: 'The status line at the bottom: the time, the agent\'s state, what the mouse is over' },
  { id: 'files', label: 'Code: file list', doc: 'The Code tab\'s Files, Open and Scratch lists, beside the editor' },
];

const shown = { side: !storage('side-hidden', false), rail: true, composer: true, wholine: true, files: true,
                ...storage('layout-shown', {}) };
let zoomed = storage('layout-zoom', false);
let peeking = false;      // the prompt shown while zoomed, for what was put there

const frame = () => document.getElementById('frame');

const unzoom = el('button', { class: 'btn btn-small unzoom', type: 'button', hidden: true,
                               'data-doc': 'Bring back the rest of the page (Alt-Z)', onclick: () => toggleZoom(false) }, '⤡ Unzoom');

export function apply() {
  const node = frame();
  if (!node) return;
  for (const region of REGIONS) node.classList.toggle(`hide-${region.id}`, !shown[region.id]);
  node.classList.toggle('zoomed', zoomed);
  node.classList.toggle('zoom-peek', zoomed && peeking);
  document.getElementById('desk')?.classList.toggle('side-hidden', !shown.side);
  if (!unzoom.isConnected) document.body.append(unzoom);
  unzoom.hidden = !zoomed;
  // Terminals and editors refit to what they now have (their ResizeObservers).
  emit('layout');
}

export function isShown(id) { return shown[id]; }

export function setShown(id, value) {
  shown[id] = value;
  store('layout-shown', shown);
  if (id === 'side') store('side-hidden', !value);
  apply();
}

export const toggle = id => setShown(id, !shown[id]);

export function toggleZoom(force) {
  zoomed = force ?? !zoomed;
  peeking = false;
  store('layout-zoom', zoomed);
  apply();
}

/** Show region ID if hidden: the prompt, when something is put there. */
export function reveal(id) {
  if (zoomed && id === 'composer') { peeking = true; apply(); return; }
  if (!shown[id]) setShown(id, true);
}

/** Back to the page as it first was: every region shown, splitters undragged. */
export function resetLayout() {
  for (const region of REGIONS) shown[region.id] = true;
  store('layout-shown', shown);
  store('side-hidden', false);
  zoomed = false;
  store('layout-zoom', false);
  for (const reset of splitterResets) reset();
  apply();
}

/** The layout as an object: the Layout menu, and inspectable. */
export function layoutObject() {
  const check = on => (on ? '✓ ' : '\u00a0\u00a0');   // no-break: the labels line up
  return {
    kind: 'Layout', title: zoomed ? 'zoomed' : 'the page', type: 'LAYOUT',
    parts: REGIONS.map(region => [region.label, shown[region.id] ? 'shown' : 'hidden']).concat([['zoom', zoomed ? 'on' : 'off']]),
    commands: [
      { label: `${check(zoomed)}Zoom: only this tab`, doc: 'Alt-Z', run: () => toggleZoom() },
      ...REGIONS.map(region => ({ label: `${check(shown[region.id])}${region.label}`, doc: region.doc, run: () => toggle(region.id) })),
      { label: 'Reset the layout', doc: 'Every region shown, every splitter where it started', danger: true, run: resetLayout },
    ],
  };
}

export function openLayoutMenu(x, y) {
  const object = layoutObject();
  openMenu(object, x, y, object.commands[0].label);
}

// ---------- splitters ----------

const splitterResets = [];

/**
 * Make HANDLE drag the boundary between two parts of CONTAINER.  The
 * fraction of CONTAINER before the boundary is kept under KEY and given to
 * SET(fraction) -- also at once, if one was kept.  The handle's cursor
 * (col-resize or row-resize, from CSS, for the layout in force) says which
 * way it drags.  Double-click: back to the default (SET(null)).
 */
export function makeSplitter(handle, { container, key, set, min = 0.1, max = 0.9 }) {
  const kept = storage(key, null);
  if (kept != null) set(kept);
  splitterResets.push(() => { store(key, null); set(null); });
  handle.addEventListener('dblclick', () => { store(key, null); set(null); emit('layout'); });
  handle.addEventListener('pointerdown', e => {
    e.preventDefault();
    const vertical = getComputedStyle(handle).cursor === 'row-resize';
    handle.classList.add('dragging');
    handle.setPointerCapture(e.pointerId);
    const move = ev => {
      const box = container.getBoundingClientRect();
      const fraction = vertical ? (ev.clientY - box.top) / box.height : (ev.clientX - box.left) / box.width;
      const value = Math.max(min, Math.min(max, fraction));
      set(value);
      store(key, value);
    };
    const up = () => {
      handle.classList.remove('dragging');
      handle.removeEventListener('pointermove', move);
      handle.removeEventListener('pointerup', up);
      emit('layout');
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', up);
  });
}

on('reveal', id => reveal(id));
