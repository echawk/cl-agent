// lisp-editor.js -- the Lisp tab's code editor: a <textarea> laid over a
// syntax-highlighted copy of its own text, so typing, undo, selection and
// IME stay native while the code shows in colour.
//
//   highlighting  comments, strings, characters, numbers, keywords, lambda-list
//                 keywords, special/defining operators and the names they
//                 define, and rainbow parentheses in the six-band palette;
//                 the partner of the paren at the cursor is boxed, an
//                 unmatched ")" is red
//   structure     parse(text) gives a tree of forms, for the symbol at point,
//                 the toplevel form at point (C-c C-c), the form before point
//                 (C-x C-e), the call around point (autodoc) and the
//                 buffer's (in-package ...) at point
//   indentation   Lisp style: body forms by 2, arguments aligned with the
//                 first one; on Enter, and on Tab within a line's indentation
//   completion    Tab anywhere else (or C-M-i) completes at point (menu.js):
//                 the server picks file names in a string, the call's keyword
//                 arguments, or symbols by prefix, m-v-b, then SLY's flex
//                 matching.  Tab inserts what every candidate shares; with
//                 the menu open, typing narrows it and Tab/C-n/C-p move
//   dabbrev       M-/ expands the word before point from the buffer's words,
//                 nearest first, then options.dabbrevText()'s; again cycles
//   keys          Emacs-style key sequences ("C-c C-c", "M-.", "C-x C-e")
//                 from the keymap its owner passes in
//
// createLispEditor(host, options) -> editor.  Options:
//   value, placeholder, className
//   keymap        { "C-c C-k": editor => ..., ... }
//   complete      async (text, cursor) => completion result (menu.js shape)
//   onEnter       (editor, event) => true when it handled Enter (the REPL's submit)
//   onKey         (editor, event) => true when it handled any other key
//   onChange      (text) => ...            onContext (call | null) => ... (autodoc)
//   onMessage     (text) => ...            (echo area: chord prefixes, "No completions")
//   dabbrevText   () => text               more words for M-/ (the other editor's)

import { createMenu, commonPrefix, menuStep, menuCancel } from './menu.js';
import { el } from './core.js';

// ---------- reading ----------

const DELIMITER = /[\s()'`,";]/;
const NUMBER = /^[+-]?(\d+\.?\d*([eEdDfFsSlL][+-]?\d+)?|\.\d+([eEdDfFsSlL][+-]?\d+)?|\d+\/\d+|#[xXbBoO][+-]?[\da-fA-F]+)$/;
const SPECIAL = new Set(`block catch eval-when flet function go if labels let let* load-time-value locally
  macrolet multiple-value-call multiple-value-prog1 progn progv quote return-from setq symbol-macrolet
  tagbody the throw unwind-protect lambda loop when unless cond case ecase ccase typecase etypecase
  ctypecase and or not dolist dotimes do do* destructuring-bind multiple-value-bind handler-case
  handler-bind restart-case ignore-errors prog1 prog2 return setf incf decf push pop declare in-package
  with-open-file with-output-to-string with-input-from-string with-slots with-accessors
  with-simple-restart assert check-type error warn signal declaim`.split(/\s+/));
const DEFINING = /^(def|define-)/;

/** Split TEXT into tokens: {type, start, end}, type one of comment string
 *  char open close quote space atom. */
export function tokenize(text) {
  const tokens = [];
  const n = text.length;
  let i = 0;
  const push = (type, start, end) => { tokens.push({ type, start, end }); i = end; };
  while (i < n) {
    const c = text[i];
    const next = text[i + 1];
    const start = i;
    if (c === ';') {
      const e = text.indexOf('\n', i);
      push('comment', start, e < 0 ? n : e);
    } else if (c === '#' && next === '|') {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (text[j] === '|' && text[j + 1] === '#') { depth -= 1; j += 2; } else if (text[j] === '#' && text[j + 1] === '|') { depth += 1; j += 2; } else j += 1;
      }
      push('comment', start, j);
    } else if (c === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      push('string', start, Math.min(n, j + 1));
    } else if (c === '(') push('open', start, i + 1);
    else if (c === '#' && next === '(') push('open', start, i + 2);
    else if (c === ')') push('close', start, i + 1);
    else if (c === "'" || c === '`') push('quote', start, i + 1);
    else if (c === ',') push('quote', start, i + (next === '@' ? 2 : 1));
    else if (c === '#' && next === "'") push('quote', start, i + 2);
    else if (c === '#' && next === '\\') {
      let j = Math.min(n, i + 3);
      while (j < n && !DELIMITER.test(text[j])) j += 1;
      push('char', start, j);
    } else if (/\s/.test(c)) {
      let j = i;
      while (j < n && /\s/.test(text[j])) j += 1;
      push('space', start, j);
    } else {
      let j = i;
      while (j < n) {
        if (text[j] === '|') { const close = text.indexOf('|', j + 1); j = close < 0 ? n : close + 1; continue; }
        if (text[j] === '\\') { j += 2; continue; }
        if (DELIMITER.test(text[j])) break;
        j += 1;
      }
      push('atom', start, Math.max(j, i + 1));
    }
  }
  return tokens;
}

/** The form tree of TEXT: lists {type:'list', start, open, end|null, children,
 *  quoted, parent}; atoms, strings and characters {type, start, end, text}.
 *  START includes any quote prefix; an unclosed list has end null. */
export function parse(text) {
  const root = { type: 'list', start: 0, open: -1, end: text.length, children: [], root: true };
  const stack = [root];
  let prefix = null;
  for (const t of tokenize(text)) {
    if (t.type === 'space' || t.type === 'comment') continue;
    const top = stack[stack.length - 1];
    if (t.type === 'quote') { prefix ??= t; continue; }
    if (t.type === 'close') {
      prefix = null;
      if (stack.length > 1) stack.pop().end = t.end;
      continue;
    }
    const node = t.type === 'open'
      ? { type: 'list', start: prefix ? prefix.start : t.start, open: t.start, end: null, children: [], quoted: !!prefix }
      : { type: t.type, start: prefix ? prefix.start : t.start, tokenStart: t.start, end: t.end, text: text.slice(t.start, t.end) };
    node.parent = top;
    top.children.push(node);
    if (node.type === 'list') stack.push(node);
    prefix = null;
  }
  return root;
}

/** True when TEXT holds a form and every list, string and #| comment in it
 *  is closed: what RET at the REPL waits for before evaluating. */
export function isComplete(text) {
  let depth = 0;
  let any = false;
  for (const t of tokenize(text)) {
    const word = text.slice(t.start, t.end);
    if (t.type === 'string' && (word.length < 2 || !word.endsWith('"'))) return false;
    if (t.type === 'comment' && word.startsWith('#|') && !word.endsWith('|#')) return false;
    if (t.type === 'open') depth += 1;
    else if (t.type === 'close') depth -= 1;
    if (t.type !== 'space' && t.type !== 'comment') any = true;
  }
  return any && depth <= 0;
}

const contains = (node, pos) => node.open < pos && (node.end === null || pos < node.end);

/** The innermost list around POS (the root when POS is at top level). */
export function listAt(root, pos) {
  let list = root;
  for (;;) {
    const inner = list.children.find(c => c.type === 'list' && contains(c, pos));
    if (!inner) return list;
    list = inner;
  }
}

/** The atom at or just before POS: {start, end, text} or null. */
export function symbolAt(text, pos) {
  for (const t of tokenize(text)) {
    if (t.start > pos) break;
    if (t.type === 'atom' && t.start <= pos && pos <= t.end) {
      const word = text.slice(t.start, t.end);
      if (!NUMBER.test(word)) return { start: t.start, end: t.end, text: word };
    }
  }
  return null;
}

/** The toplevel form containing POS, else the last one before it. */
export function toplevelAt(root, pos) {
  const forms = root.children;
  return forms.find(f => f.start <= pos && pos <= (f.end ?? Infinity))
    || [...forms].reverse().find(f => (f.end ?? Infinity) <= pos)
    || forms[0] || null;
}

/** The complete form ending at or before POS, at POS's own level. */
export function sexpBefore(root, pos) {
  const list = listAt(root, pos);
  return [...list.children].reverse().find(c => c.end !== null && c.end <= pos)
    || list.children.find(c => c.start <= pos && pos <= (c.end ?? Infinity)) || null;
}

/** The call around POS: {operator, index, keyword} for autodoc, or null. */
export function callAt(root, pos) {
  let list = listAt(root, pos);
  while (list && !list.root) {
    const [operator, ...args] = list.children;
    if (operator?.type === 'atom' && !list.quoted && !operator.text.startsWith(':')) {
      if (pos <= operator.end) return { operator: operator.text, index: null, keyword: null };
      let index = args.findIndex(a => a.start <= pos && pos <= (a.end ?? Infinity));
      let keyword = null;
      if (index >= 0 && args[index].type === 'atom' && args[index].text.startsWith(':')) keyword = args[index].text;
      if (index < 0) index = args.filter(a => a.end !== null && a.end <= pos).length;
      const before = args[index - 1];
      if (!keyword && before?.type === 'atom' && before.text.startsWith(':')) keyword = before.text;
      return { operator: operator.text, index, keyword };
    }
    list = list.parent;
  }
  return null;
}

/** The package an (in-package ...) before POS selects, or null. */
export function packageAt(root, pos) {
  let name = null;
  for (const form of root.children) {
    if (form.start >= pos) break;
    const [head, arg] = form.type === 'list' ? form.children : [];
    if (head?.type === 'atom' && /^(cl:|common-lisp:)?in-package$/i.test(head.text) && arg) {
      name = arg.text.replace(/^#?:/, '').replace(/^"|"$/g, '');
    }
  }
  return name;
}

// ---------- indentation ----------

const BODY = /^(def|define-|with-|do-|do\*?$|dolist$|dotimes$|let\*?$|flet$|labels$|macrolet$|symbol-macrolet$|lambda$|when$|unless$|handler-|restart-|block$|catch$|unwind-protect$|progn$|prog1$|prog2$|case$|ecase$|ccase$|typecase$|etypecase$|ctypecase$|multiple-value-bind$|destructuring-bind$|eval-when$|print-unreadable-object$|locally$|tagbody$)/i;

const column = (text, pos) => pos - (text.lastIndexOf('\n', pos - 1) + 1);

/** Columns of indentation for a line starting at POS. */
export function indentFor(text, pos) {
  const before = text.slice(0, pos);
  let list = parse(before);
  for (;;) {
    const last = list.children[list.children.length - 1];
    if (last?.type === 'list' && last.end === null) list = last; else break;
  }
  if (list.root) return 0;
  const base = column(text, list.open) + (text[list.open] === '#' ? 1 : 0);
  const [first, second] = list.children;
  if (!first) return base + 1;
  if (first.type !== 'atom' || list.quoted) return column(text, first.start);
  const name = first.text.replace(/^.*:/, '');
  if (!first.text.startsWith(':') && BODY.test(name)) return base + 2;
  if (second && !before.slice(first.end, second.start).includes('\n')) return column(text, second.start);
  return base + 1;
}

// ---------- highlighting ----------

/** TEXT as highlighted HTML.  CARET (or -1) places a .le-caret marker and
 *  boxes the paren matching the one beside it; FLASH {start, end} marks a
 *  region (a form just sent to Lisp). */
export function markup(text, caret = -1, flash = null) {
  const tokens = tokenize(text);
  const partner = new Map();
  const unmatched = new Set();
  const depth = new Map();
  const opens = [];
  for (const t of tokens) {
    if (t.type === 'open') { depth.set(t, opens.length); opens.push(t); } else if (t.type === 'close') {
      const open = opens.pop();
      if (open) { partner.set(open, t); partner.set(t, open); depth.set(t, depth.get(open)); } else unmatched.add(t);
    }
  }
  let match = null;
  if (caret >= 0) {
    const at = tokens.find(t => t.start === caret && t.type === 'open') || tokens.find(t => t.end === caret && t.type === 'close');
    if (at && partner.has(at)) match = [at, partner.get(at)];
  }
  let html = '';
  let previous = null;      // the previous significant token
  let defining = false;     // the next atom is the name a def... form defines
  for (const t of tokens) {
    const word = text.slice(t.start, t.end);
    let cls = '';
    let startsDefinition = false;
    if (t.type === 'comment') cls = 'sx-comment';
    else if (t.type === 'string') cls = 'sx-string';
    else if (t.type === 'char') cls = 'sx-char';
    else if (t.type === 'quote') cls = 'sx-quote';
    else if (t.type === 'open' || t.type === 'close') {
      cls = unmatched.has(t) ? 'sx-paren sx-bad' : `sx-paren sx-p${(depth.get(t) ?? 0) % 6}`;
      if (match && match.includes(t)) cls += ' sx-match';
    } else if (t.type === 'atom') {
      const lower = word.toLowerCase();
      const name = lower.replace(/^.*:/, '');
      if (NUMBER.test(word)) cls = 'sx-number';
      else if (word.startsWith(':')) cls = 'sx-keyword';
      else if (word.startsWith('&')) cls = 'sx-lambda';
      else if (lower === 'nil' || lower === 't') cls = 'sx-constant';
      else if (defining) cls = 'sx-def';
      else if (previous?.type === 'open' && DEFINING.test(name)) { cls = 'sx-operator'; startsDefinition = true; } else if (previous?.type === 'open' && SPECIAL.has(name)) cls = 'sx-operator';
      else if (/^\*.+\*$/.test(word)) cls = 'sx-special';
    }
    html += piece(t, word, cls);
    if (t.type !== 'space' && t.type !== 'comment') {
      defining = startsDefinition;
      previous = t;
    }
  }
  if (caret === text.length) html += '<span class="le-caret"></span>';
  return html;

  function piece(t, word, cls) {
    const flashed = flash && t.start < flash.end && t.end > flash.start ? ' sx-flash' : '';
    const open = cls || flashed ? `<span class="${cls}${flashed}">` : '';
    const close = open ? '</span>' : '';
    if (caret > t.start && caret < t.end) {
      const cut = caret - t.start;
      return `${open}${esc(word.slice(0, cut))}${close}<span class="le-caret"></span>${open}${esc(word.slice(cut))}${close}`;
    }
    return `${caret === t.start ? '<span class="le-caret"></span>' : ''}${open}${esc(word)}${close}`;
  }
}

/** TEXT highlighted, for display (no caret). */
export const highlight = text => markup(text);

// ---------- the editor ----------

const esc = s => s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

function keyName(e) {
  const named = { Enter: 'RET', Tab: 'TAB', Escape: 'ESC', ' ': 'SPC', Backspace: 'DEL' }[e.key];
  let key = named || (e.code?.startsWith('Key') ? e.code.slice(3).toLowerCase()
    : e.code === 'Period' ? '.' : e.code === 'Comma' ? ',' : e.code === 'Slash' ? '/' : e.key);
  if (!named && e.shiftKey && /^[a-z]$/.test(key)) key = key.toUpperCase();
  return `${e.ctrlKey ? 'C-' : ''}${e.altKey ? 'M-' : ''}${key}`;
}

export function createLispEditor(host, options = {}) {
  const keymap = {
    'C-M-i': editor => editor.complete(),
    'M-TAB': editor => editor.complete(),
    'M-/': editor => editor.dabbrev(),
    ...options.keymap,
  };
  const prefixes = new Set(Object.keys(keymap).flatMap(seq => {
    const parts = seq.split(' ');
    return parts.slice(1).map((_, i) => parts.slice(0, i + 1).join(' '));
  }));
  const view = el('pre', { class: 'le-view', 'aria-hidden': 'true' });
  const input = el('textarea', {
    class: 'le-input', spellcheck: 'false', autocapitalize: 'off', autocomplete: 'off',
    placeholder: options.placeholder || '', 'data-doc': options.doc || '',
  });
  const stack = el('div', { class: 'le-stack' }, view, input);
  const scroller = el('div', { class: 'le-scroll' }, stack);
  const menuNode = el('div', { class: 'completions le-menu', hidden: true });
  const root = el('div', { class: `lisp-editor ${options.className || ''}` }, scroller, menuNode);
  host.append(root);
  input.value = options.value || '';

  let pending = null;         // a key-sequence prefix, e.g. "C-c"
  let flash = null;           // {start, end} briefly highlighted
  let lastContext = '';
  let contextTimer = null;
  let requestNumber = 0;
  let follow = false;         // keep the caret in view after this render
  let refining = false;       // the menu is open and a key just changed the token
  let expansion = null;       // the M-/ in progress: {start, prefix, words, index, end}

  const message = text => options.onMessage?.(text);

  // ----- highlighting -----

  function render() {
    const caret = input.selectionStart === input.selectionEnd ? input.selectionStart : -1;
    view.innerHTML = `${markup(input.value, caret, flash)}\n`;
    if (follow) { follow = false; keepCaretVisible(); }
  }

  // Text changes repaint at once; cursor moves are batched to the next
  // frame (or a short timer, where frames are throttled, e.g. hidden tabs).
  let frame = 0;
  let timer = 0;
  function schedule({ keep = false, now = false } = {}) {
    follow = follow || keep;
    if (now) { cancelAnimationFrame(frame); clearTimeout(timer); frame = 0; timer = 0; render(); return; }
    if (frame || timer) return;
    const run = () => { cancelAnimationFrame(frame); clearTimeout(timer); frame = 0; timer = 0; render(); };
    frame = requestAnimationFrame(run);
    timer = setTimeout(run, 60);
  }

  function caretRect() {
    return view.querySelector('.le-caret')?.getBoundingClientRect() || input.getBoundingClientRect();
  }

  function keepCaretVisible() {
    const caret = view.querySelector('.le-caret');
    if (!caret) return;
    const box = scroller.getBoundingClientRect();
    const rect = caret.getBoundingClientRect();
    const line = parseFloat(getComputedStyle(view).lineHeight) || 20;
    if (rect.bottom + 4 > box.bottom) scroller.scrollTop += rect.bottom + 4 - box.bottom;
    else if (rect.top - 4 < box.top) scroller.scrollTop -= box.top - rect.top + 4;
    if (rect.top < box.top - line) scroller.scrollTop = Math.max(0, scroller.scrollTop - line);
  }

  // ----- editing -----

  function replaceRange(start, end, text) {
    input.focus();
    input.setSelectionRange(start, end);
    if (!document.execCommand('insertText', false, text)) {
      input.setRangeText(text, start, end, 'end');
      input.dispatchEvent(new Event('input'));
    }
  }

  function lineStartOf(pos) { return input.value.lastIndexOf('\n', pos - 1) + 1; }

  function indentLine(lineStart) {
    const text = input.value;
    const current = /^[ \t]*/.exec(text.slice(lineStart))[0];
    const want = indentFor(text, lineStart);
    if (current !== ' '.repeat(want)) replaceRange(lineStart, lineStart + current.length, ' '.repeat(want));
    return want;
  }

  function indentRegion(start, end) {
    let line = lineStartOf(start);
    while (line <= end) {
      const before = input.value.length;
      indentLine(line);
      end += input.value.length - before;
      const next = input.value.indexOf('\n', line);
      if (next < 0) break;
      line = next + 1;
    }
  }

  function newlineAndIndent() {
    const pos = input.selectionStart;
    const text = input.value.slice(0, pos) + '\n';
    replaceRange(pos, input.selectionEnd, `\n${' '.repeat(indentFor(text, text.length))}`);
  }

  // ----- completion -----

  const menu = createMenu(menuNode, { onAccept: accept });

  function placeMenu() {
    const rect = caretRect();
    menuNode.style.left = `${Math.max(8, Math.min(rect.left - 8, window.innerWidth - Math.min(680, window.innerWidth - 16) - 8))}px`;
    const height = menuNode.offsetHeight;
    const below = rect.bottom + 6;
    menuNode.style.top = `${below + height > window.innerHeight - 8 ? Math.max(8, rect.top - height - 6) : below}px`;
  }

  function accept(candidate, result) {
    replaceRange(result.start, result.end, candidate.value);
    menu.hide();
  }

  // REFINE: the menu is open and the user typed; show the new candidates
  // but never insert or accept anything on their behalf.
  async function complete({ refine = false } = {}) {
    if (!options.complete) return;
    const text = input.value;
    const cursor = input.selectionStart;
    const number = ++requestNumber;
    let result;
    try { result = await options.complete(text, cursor); } catch (err) { message(err.message); return; }
    if (number !== requestNumber || input.value !== text || !result) return;
    const { candidates } = result;
    const typed = text.slice(result.start, result.end);
    if (!candidates.length) { menu.hide(); if (!refine) message(`No completions for "${result.token}".`); return; }
    if (candidates.length === 1 && candidates[0].value === typed) {
      menu.hide();
      if (!refine) message('Sole completion');
      return;
    }
    if (refine) { menu.show(result, 0); placeMenu(); return; }
    if (candidates.length === 1) { accept(candidates[0], result); return; }
    // Only a common part that extends what was typed: a flex match's
    // candidates need not start with it.
    const common = commonPrefix(candidates.map(c => c.value));
    if (common.length > typed.length && common.toLowerCase().startsWith(typed.toLowerCase())) {
      replaceRange(result.start, result.end, common);
      result.end = result.start + common.length;
    }
    menu.show(result, 0);
    placeMenu();
  }

  // Keys that change the token being completed, so an open menu follows them.
  const refines = e => !e.ctrlKey && !e.altKey && !e.metaKey
    && (e.key === 'Backspace' || (e.key.length === 1 && !DELIMITER.test(e.key)));

  // ----- M-/ (dabbrev-expand) -----

  function dabbrevWords(text, start, prefix) {
    const lower = prefix.toLowerCase();
    const words = source => tokenize(source).filter(t => t.type === 'atom')
      .map(t => ({ t, word: source.slice(t.start, t.end) }))
      .filter(({ word }) => word.length > prefix.length && word.toLowerCase().startsWith(lower));
    const here = words(text).filter(({ t }) => t.start !== start);
    const before = here.filter(({ t }) => t.end <= start).reverse();
    const after = here.filter(({ t }) => t.start > start);
    const elsewhere = words(options.dabbrevText?.() || '');
    return [...new Set([...before, ...after, ...elsewhere].map(({ word }) => word))];
  }

  function dabbrev() {
    const text = input.value;
    const pos = input.selectionStart;
    if (!expansion || expansion.end !== pos || text.slice(expansion.start, pos) !== expansion.words[expansion.index]) {
      let start = pos;
      while (start > 0 && !DELIMITER.test(text[start - 1])) start -= 1;
      const prefix = text.slice(start, pos);
      if (!prefix) { message('No dynamic expansion for an empty word'); return; }
      expansion = { start, prefix, words: dabbrevWords(text, start, prefix), index: -1 };
    }
    expansion.index += 1;
    const word = expansion.words[expansion.index];
    if (word === undefined) {
      const { start, prefix } = expansion;
      expansion = null;
      if (pos !== start + prefix.length || text.slice(start, pos) !== prefix) replaceRange(start, pos, prefix);
      message(`No further dynamic expansions for "${prefix}" found`);
      return;
    }
    replaceRange(expansion.start, pos, word);
    expansion.end = expansion.start + word.length;
  }

  // ----- keys -----

  function onKeyDown(e) {
    if (e.isComposing) return;
    const state = menu.state;
    if (state) {
      const step = menuStep(e);
      if (step) { e.preventDefault(); menu.move(step); return; }
      if (e.key === 'Enter' && menu.selected) { e.preventDefault(); accept(menu.selected, state.result); return; }
      if (menuCancel(e)) { e.preventDefault(); menu.hide(); return; }
      if (refines(e)) refining = true;
      else if (!['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) menu.hide();
    }
    if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
    const name = keyName(e);
    const sequence = pending ? `${pending} ${name}` : name;
    const selecting = input.selectionStart !== input.selectionEnd;
    if (!pending && selecting && (name === 'C-c' || name === 'C-x')) return;   // copy / cut
    if (keymap[sequence]) {
      e.preventDefault();
      pending = null;
      message('');
      keymap[sequence](api, e);
      return;
    }
    if (prefixes.has(sequence)) { e.preventDefault(); pending = sequence; message(`${sequence}-`); return; }
    if (pending) { e.preventDefault(); pending = null; message(`${sequence} is undefined`); return; }
    if (options.onKey?.(api, e)) { e.preventDefault(); return; }
    if (e.key === 'Escape') return;
    if (e.key === 'Tab' && !e.ctrlKey && !e.altKey && !e.metaKey) {
      e.preventDefault();
      if (e.shiftKey) return;
      const { selectionStart: start, selectionEnd: end, value } = input;
      if (start !== end && value.slice(start, end).includes('\n')) { indentRegion(start, end); return; }
      const lineStart = lineStartOf(start);
      if (/^[ \t]*$/.test(value.slice(lineStart, start))) {
        const want = indentLine(lineStart);
        input.setSelectionRange(lineStart + want, lineStart + want);
        schedule({ keep: true });
      } else complete();
      return;
    }
    if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (options.onEnter?.(api, e)) { e.preventDefault(); return; }
      e.preventDefault();
      newlineAndIndent();
    }
  }

  function contextChanged() {
    clearTimeout(contextTimer);
    contextTimer = setTimeout(() => {
      const call = input.selectionStart === input.selectionEnd ? callAt(parse(input.value), input.selectionStart) : null;
      const key = JSON.stringify(call);
      if (key !== lastContext) { lastContext = key; options.onContext?.(call); }
    }, 180);
  }

  input.addEventListener('keydown', onKeyDown);
  input.addEventListener('input', () => {
    schedule({ keep: true, now: true });
    contextChanged();
    options.onChange?.(input.value);
    if (refining) { refining = false; if (menu.state) complete({ refine: true }); }
  });
  input.addEventListener('keyup', () => { schedule(); contextChanged(); });
  input.addEventListener('mouseup', () => { schedule(); contextChanged(); });
  input.addEventListener('focus', () => { schedule(); contextChanged(); });
  input.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== input) menu.hide(); }, 150));
  document.addEventListener('selectionchange', () => { if (document.activeElement === input) schedule(); });

  // ----- the public face -----

  const api = {
    root, input,
    get value() { return input.value; },
    set value(text) {
      const caret = Math.min(input.selectionStart, text.length);
      input.value = text;
      input.setSelectionRange(caret, caret);
      schedule({ now: true });
    },
    get cursor() { return input.selectionStart; },
    get selection() { return { start: input.selectionStart, end: input.selectionEnd, text: input.value.slice(input.selectionStart, input.selectionEnd) }; },
    focus() { input.focus(); },
    setCursor(pos) { input.setSelectionRange(pos, pos); schedule({ keep: true }); },
    replaceRange,
    insert(text) { replaceRange(input.selectionStart, input.selectionEnd, text); },
    complete,
    dabbrev,
    tree() { return parse(input.value); },
    symbolAtPoint() { return symbolAt(input.value, input.selectionStart); },
    toplevelAtPoint() {
      const form = toplevelAt(parse(input.value), input.selectionStart);
      return form && { start: form.start, end: form.end ?? input.value.length, text: input.value.slice(form.start, form.end ?? undefined) };
    },
    sexpBeforePoint() {
      const form = sexpBefore(parse(input.value), input.selectionStart);
      return form && { start: form.start, end: form.end ?? input.value.length, text: input.value.slice(form.start, form.end ?? undefined) };
    },
    packageAtPoint() { return packageAt(parse(input.value), input.selectionStart); },
    lineOf(pos) { return input.value.slice(0, pos).split('\n').length; },
    flash(start, end) {
      flash = { start, end };
      schedule();
      setTimeout(() => { flash = null; schedule(); }, 450);
    },
    refresh() { schedule(); },
  };
  render();
  return api;
}
