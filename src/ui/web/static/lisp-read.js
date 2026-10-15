// lisp-read.js -- just enough of the Lisp reader to tell, as you type, a
// form from prose at the main prompt (forms.js, composer.js).  No DOM: the
// test suite runs it under node (t/test-web.lisp).
//
// classify(text) is 'command' (/name), 'form' (nothing but Lisp forms at
// top level, or a leading comma), 'open-form' (a form still being typed),
// 'ask' (anything else: a request to the agent) or 'empty'.

const OPEN = new Set(['(', "'", '`', '#', ',']);
const DELIMITER = /[\s()"'`;]/;
const INCOMPLETE = -1;

function skipBlank(t, i) {
  for (;;) {
    while (i < t.length && /\s/.test(t[i])) i += 1;
    if (t[i] === ';') { while (i < t.length && t[i] !== '\n') i += 1; continue; }
    if (t[i] === '#' && t[i + 1] === '|') {
      const end = t.indexOf('|#', i + 2);
      if (end < 0) return t.length;
      i = end + 2;
      continue;
    }
    return i;
  }
}

function readAtom(t, i) {
  while (i < t.length && !DELIMITER.test(t[i])) {
    if (t[i] === '\\') i += 1;
    if (t[i] === '|') { const end = t.indexOf('|', i + 1); if (end < 0) return INCOMPLETE; i = end; }
    i += 1;
  }
  return i;
}

function readString(t, i) {
  for (i += 1; i < t.length; i += 1) {
    if (t[i] === '\\') i += 1;
    else if (t[i] === '"') return i + 1;
  }
  return INCOMPLETE;
}

function readList(t, i) {
  for (i += 1; ;) {
    i = skipBlank(t, i);
    if (i >= t.length) return INCOMPLETE;
    if (t[i] === ')') return i + 1;
    i = readItem(t, i);
    if (i === INCOMPLETE) return INCOMPLETE;
  }
}

function readItem(t, i) {
  const c = t[i];
  if (i >= t.length) return INCOMPLETE;
  if (c === "'" || c === '`') return readItem(t, skipBlank(t, i + 1));
  if (c === ',') return readItem(t, skipBlank(t, i + (t[i + 1] === '@' ? 2 : 1)));
  if (c === '(') return readList(t, i);
  if (c === '"') return readString(t, i);
  if (c === '#') {
    const d = t[i + 1];
    if (d === undefined) return INCOMPLETE;
    if (d === "'") return readItem(t, i + 2);
    if (d === '(') return readList(t, i + 1);
    if (d === '\\') return readAtom(t, i + 3);
    if (d === '+' || d === '-') {
      const feature = readItem(t, i + 2);
      return feature === INCOMPLETE ? INCOMPLETE : readItem(t, skipBlank(t, feature));
    }
    // #p"...", #x1F, #:sym, #.(...), #1A(...)
    let j = i + 1;
    while (j < t.length && /[\w:.]/.test(t[j])) j += 1;
    return t[j] === '(' || t[j] === '"' ? readItem(t, j) : j;
  }
  return readAtom(t, i);
}

/** What TEXT at the main prompt is: 'command', 'form', 'open-form' (a form
still being typed: Enter adds a newline), 'ask' or 'empty'. */
export function classify(text) {
  const t = text.trimStart();
  if (!t) return 'empty';
  if (t.startsWith('/')) return 'command';
  if (t.startsWith(',')) return t.length > 1 ? 'form' : 'open-form';
  if (!OPEN.has(t[0])) return 'ask';
  for (let i = 0; ;) {
    i = skipBlank(t, i);
    if (i >= t.length) return 'form';
    if (!OPEN.has(t[i]) && t[i] !== '"') return 'ask';    // a bare word: prose
    i = readItem(t, i);
    if (i === INCOMPLETE) return 'open-form';
  }
}
