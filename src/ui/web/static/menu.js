// menu.js -- the completion menu (an Interlisp pop-up menu) shared by the
// composer and the Lisp editors: a titled list of candidates, each
// "value · kind · doc", with one selected and the letters the typed text
// matched (a candidate's `match`, [start, end] ranges of its display) marked.
//
//   const menu = createMenu(node, { onAccept: candidate => ... });
//   menu.show(result, index)   result: {candidates, total, source}
//   menu.move(+1 | -1)  menu.hide()  menu.state -> {result, index} | null
//   menuStep(e)    +1 / -1 for the keys that move the selection (Tab,
//                  Shift-Tab, ↓ ↑, and Emacs's C-n C-p), else 0
//   menuCancel(e)  whether the key closes the menu (Esc, C-g)
//
// `result` is what GET /api/complete or /api/lisp/complete returns.

import { el } from './core.js';

const TITLES = {
  'slash-commands': 'Commands',
  paths: 'Files',
  'lisp-symbols': 'Lisp symbols',
  lisp: 'Lisp symbols',
  'lisp-abbreviations': 'Lisp symbols · abbreviation',
  'lisp-flex': 'Lisp symbols · flex',
  'lisp-keywords': 'Keyword arguments',
  'lisp-files': 'Files',
  lsp: 'Language server',
  'buffer-words': 'Words in this buffer',
};

const plainCtrl = e => e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey;

export function menuStep(e) {
  if (e.key === 'Tab' && !e.ctrlKey && !e.altKey && !e.metaKey) return e.shiftKey ? -1 : 1;
  if (e.key === 'ArrowDown' && !e.ctrlKey && !e.metaKey) return 1;
  if (e.key === 'ArrowUp' && !e.ctrlKey && !e.metaKey) return -1;
  if (plainCtrl(e) && e.code === 'KeyN') return 1;
  if (plainCtrl(e) && e.code === 'KeyP') return -1;
  return 0;
}

export function menuCancel(e) {
  return e.key === 'Escape' || (plainCtrl(e) && e.code === 'KeyG');
}

export function menuTitle(source) {
  if (source?.startsWith('command:')) return `/${source.slice(8)} arguments`;
  return TITLES[source] || 'Possibilities';
}

export function createMenu(node, { onAccept }) {
  let current = null;

  function show(result, index = 0) {
    current = { result, index };
    const { candidates, total } = result;
    node.replaceChildren(
      el('div', { class: 'completions-title' },
        el('span', {}, menuTitle(result.source)),
        el('span', {}, `${candidates.length}${total > candidates.length ? ` of ${total}` : ''} · Tab ↑↓ C-n C-p Enter Esc`)),
      el('div', { class: 'completions-list', role: 'listbox' },
        candidates.map((c, i) => el('div', {
          class: `completion kind-${c.kind || 'other'} ${i === index ? 'selected' : ''}`,
          role: 'option',
          'data-doc': c.doc || c.value,
          onmousedown: e => { e.preventDefault(); onAccept(c, result); },
        }, el('span', { class: 'c-value' }, marked(c.display || c.value, c.match)),
           el('span', { class: 'c-kind' }, c.kind || ''),
           el('span', { class: 'c-doc' }, c.doc || '')))));
    // One value column for every row, sized to the longest candidate.
    const widest = Math.max(...candidates.map(c => (c.display || c.value).length));
    node.style.setProperty('--completion-value-width', `${Math.min(Math.max(widest, 8), 36) + 1}ch`);
    node.hidden = false;
    node.querySelector('.completion.selected')?.scrollIntoView({ block: 'nearest' });
  }

  function move(delta) {
    if (!current) return;
    const { result, index } = current;
    const n = result.candidates.length;
    show(result, index < 0 ? (delta > 0 ? 0 : n - 1) : (index + delta + n) % n);
  }

  function hide() {
    current = null;
    node.hidden = true;
    node.replaceChildren();
  }

  return {
    show, move, hide,
    get state() { return current; },
    get selected() { return current && current.index >= 0 ? current.result.candidates[current.index] : null; },
  };
}

/** TEXT with the [start, end] RANGES wrapped in <mark>. */
function marked(text, ranges) {
  if (!ranges?.length) return text;
  const parts = [];
  let at = 0;
  for (const [start, end] of ranges) {
    if (start < at || end > text.length) continue;
    parts.push(text.slice(at, start), el('mark', { class: 'c-match' }, text.slice(start, end)));
    at = end;
  }
  parts.push(text.slice(at));
  return parts;
}

/** Longest common prefix of VALUES, ignoring case. */
export function commonPrefix(values) {
  if (!values.length) return '';
  let prefix = values[0];
  for (const value of values) {
    let i = 0;
    while (i < prefix.length && i < value.length && prefix[i].toLowerCase() === value[i].toLowerCase()) i += 1;
    prefix = prefix.slice(0, i);
  }
  return prefix;
}
