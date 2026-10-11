// menu.js -- the completion menu (an Interlisp pop-up menu) shared by the
// composer and the Lisp editors: a titled list of candidates, each
// "value · kind · doc", with one selected.
//
//   const menu = createMenu(node, { onAccept: candidate => ... });
//   menu.show(result, index)   result: {candidates, total, source}
//   menu.move(+1 | -1)  menu.hide()  menu.state -> {result, index} | null
//
// `result` is what GET /api/complete or /api/lisp/complete returns.

import { el } from './core.js';

const TITLES = {
  'slash-commands': 'Commands',
  paths: 'Files',
  'lisp-symbols': 'Lisp symbols',
  lisp: 'Lisp symbols',
  'lisp-abbreviations': 'Lisp symbols · abbreviation',
};

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
        el('span', {}, `${candidates.length}${total > candidates.length ? ` of ${total}` : ''} · Tab ↑↓ Enter Esc`)),
      el('div', { class: 'completions-list', role: 'listbox' },
        candidates.map((c, i) => el('div', {
          class: `completion kind-${c.kind || 'other'} ${i === index ? 'selected' : ''}`,
          role: 'option',
          'data-doc': c.doc || c.value,
          onmousedown: e => { e.preventDefault(); onAccept(c, result); },
        }, el('span', { class: 'c-value' }, c.display || c.value),
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
