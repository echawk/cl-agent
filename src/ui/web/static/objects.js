// objects.js -- everything on the screen is an object you can look at.
//
// As on a Lisp machine, a thing drawn on the screen is a *presentation* of
// an object: the mouse highlights it, the who-line says what the buttons
// do, Left does the obvious thing, Right opens the object's menu of
// commands, and Inspect shows its parts in the Inspect panel -- whose parts
// are presentations too, so curiosity can keep going.  Lisp values,
// messages, tool calls, agents, tools, files, sessions and the keymap all
// work this way; there is one inspector, not a detail card per kind.
//
//   present(node, describe, {left})   make NODE a presentation; DESCRIBE()
//                                     returns the object (see below), LEFT
//                                     is the left-click command's label
//   inspect(object)                   show OBJECT in the Inspect panel
//   inspectLisp(id)                   ... a Lisp value the REPL presented
//   lispObject(text, id, type)        the object for such a value
//   openMenu(object, x, y)            the right-button menu
//
// An object is {kind, title, type?, parts?, commands?, text?, about?, refresh?}:
//   parts     [[label, value]]: a string, a DOM node, {object: o} (a
//             presentation of another object) or {lisp: {text, id, type}}
//   commands  [{label, doc?, run(object)}]: its own commands, first is Left's
//             default unless present() names one
//   text      what Copy copies;  about  how "Ask the agent" names it
//   refresh() an async function returning the object anew (↻ Refresh)

import { el, api, state, registerPanel, copyText, fmtClock, fmtDuration, fmtCount, now, clientCommands } from './core.js';
import { showPanel } from './panels.js';
import { insert as insertInComposer } from './composer.js';
import { classify, evaluate as evaluateForm } from './forms.js';

const toast = (text, color) => window.CLAgent?.toast(text, color);

// ---------- commands every object has ----------

function commandsFor(object) {
  const own = object.commands || [];
  const common = [{ label: 'Inspect', doc: 'Show its parts in the Inspect panel', run: () => inspect(object) }];
  if (object.about) {
    common.push({
      label: 'Ask the agent about it', doc: 'Put it at the prompt as the subject of a question',
      run: () => insertInComposer(`About ${object.about}: `),
    });
  }
  if (object.text) common.push({ label: 'Copy', doc: 'Copy it as text', run: () => copyText(object.text) });
  const all = [...own, ...common.filter(c => !own.some(o => o.label === c.label))];
  // What cannot be undone goes last, where a slip of the mouse does not land.
  return [...all.filter(c => !c.danger), ...all.filter(c => c.danger)];
}

/** The menu's order: LEFT's command first (as the mouse line promises). */
function menuOrder(object, left) {
  const all = commandsFor(object);
  const first = all.find(c => c.label === left && !c.danger);
  return first ? [first, ...all.filter(c => c !== first)] : all;
}

// ---------- presentations ----------

const described = new WeakMap();   // node -> describe()

/** Make NODE a presentation of the object DESCRIBE() returns.  Left runs
the command labelled LEFT (default: Inspect); Right opens the menu. */
export function present(node, describe, { left = 'Inspect' } = {}) {
  described.set(node, describe);
  node.classList.add('presentation', 'mouse');
  node.dataset.left = left;
  if (!node.dataset.doc) node.dataset.doc = '';
  const runLeft = () => {
    const object = describe();
    if (!object) return false;
    const command = commandsFor(object).find(c => c.label === left) || commandsFor(object)[0];
    command?.run(object);
    return true;
  };
  node.addEventListener('click', e => {
    if (e.button !== 0 || e.altKey || e.defaultPrevented) return;
    e.preventDefault();
    e.stopPropagation();
    runLeft();
  });
  // From the keyboard: Tab to it, Enter is Left, the Menu key (or Shift-F10) is Right.
  if (node.tabIndex < 0 && !/^(BUTTON|A|INPUT|TEXTAREA|SELECT)$/.test(node.tagName)) node.tabIndex = 0;
  node.addEventListener('keydown', e => {
    if (e.target !== node) return;
    if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); runLeft(); }
    else if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) {
      e.preventDefault();
      const object = describe();
      const box = node.getBoundingClientRect();
      if (object) openMenu(object, box.left, box.bottom, left);
    }
  });
  node.addEventListener('focus', () => window.CLAgent?.mousedoc?.(presentationDoc(node) || ''));
  return node;
}

/** The who-line's line for presentation NODE (main.js shows it on hover). */
export function presentationDoc(node) {
  const describe = described.get(node);
  const object = describe?.();
  if (!object) return null;
  const doc = node.dataset.doc ? ` · ${node.dataset.doc}` : '';
  return `L: ${node.dataset.left.toLowerCase()} · R: menu — ${object.kind} ${clip(object.title, 48)}${doc}`;
}

/** Text you selected, as an object: what you are pointing at in a reply
or a transcript can be asked about, evaluated or copied. */
export function selectionObject(text) {
  const form = classify(text) === 'form';
  return {
    kind: 'Selection', title: clip(text.replace(/\s+/g, ' '), 50), type: form ? 'TEXT (A LISP FORM)' : 'TEXT', text,
    parts: [['characters', String(text.length)], ['lines', String(text.split('\n').length)], ['text', text]],
    commands: [
      { label: 'Ask the agent about it', doc: 'Put it at the prompt, quoted', run: () => insertInComposer(`About this:\n\`\`\`\n${text}\n\`\`\`\n`) },
      ...(form ? [{ label: 'Evaluate it', doc: 'In the image, at the listener', run: () => evaluateForm(text).catch(err => toast(err.message, 'red')) }] : []),
      { label: 'Put it at the prompt', run: () => insertInComposer(text) },
    ],
  };
}

function selectedText(target) {
  const selection = window.getSelection();
  const text = selection && !selection.isCollapsed ? selection.toString() : '';
  if (!text.trim() || !target.closest?.('#listener, .panel-body, .repl-transcript, .session-transcript')) return '';
  return text;
}

// The right button, anywhere: the menu of the presentation under it -- or
// of the text you selected.
document.addEventListener('contextmenu', e => {
  if (e.shiftKey) return;                          // Shift-right: the browser's own menu
  const node = e.target.closest?.('.presentation');
  const describe = node && described.get(node);
  const text = describe ? '' : selectedText(e.target);
  const object = describe ? describe() : text ? selectionObject(text) : null;
  if (!object) return;
  e.preventDefault();
  openMenu(object, e.clientX, e.clientY, node?.dataset.left);
});

// ---------- the menu (an Interlisp pop-up) ----------

let menu = null;

function closeMenu() {
  menu?.node.remove();
  menu?.from?.focus?.({ preventScroll: true });
  menu = null;
}

export function openMenu(object, x, y, left = 'Inspect') {
  closeMenu();
  const commands = menuOrder(object, left);
  let index = 0;
  const items = commands.map((command, i) => el('button', {
    class: `objmenu-item ${command.danger ? 'danger' : ''}`, type: 'button', role: 'menuitem', 'data-doc': command.doc || command.label,
    onclick: () => { if (menu) menu.from = null; closeMenu(); command.run(object); },
    onmouseenter: () => select(i),
  }, command.label));
  const node = el('div', { class: 'objmenu', role: 'menu', 'aria-label': `${object.kind} ${object.title}` },
    el('div', { class: 'objmenu-title' }, el('span', {}, object.kind), el('span', { class: 'objmenu-name' }, object.title)),
    items);
  function select(i) {
    index = (i + items.length) % items.length;
    items.forEach((item, j) => item.classList.toggle('selected', j === index));
    items[index].focus({ preventScroll: true });
  }
  node.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown' || (e.ctrlKey && e.key === 'n')) { e.preventDefault(); select(index + 1); }
    else if (e.key === 'ArrowUp' || (e.ctrlKey && e.key === 'p')) { e.preventDefault(); select(index - 1); }
    else if (e.key === 'Escape') { e.preventDefault(); closeMenu(); }
  });
  document.body.append(node);
  const box = node.getBoundingClientRect();
  node.style.left = `${Math.max(4, Math.min(x, innerWidth - box.width - 8))}px`;
  node.style.top = `${Math.max(4, Math.min(y, innerHeight - box.height - 8))}px`;
  menu = { node, from: document.activeElement !== document.body ? document.activeElement : null };
  select(0);
}

document.addEventListener('mousedown', e => { if (menu && !menu.node.contains(e.target)) closeMenu(); }, true);
window.addEventListener('blur', closeMenu);

// ---------- Lisp values ----------

const reference = id => `(cl-agent::lisp-repl-object ${id})`;

/** The object for Lisp value ID, printed as TEXT. */
export function lispObject(text, id, type = '') {
  return {
    kind: 'Lisp object', title: text.length > 60 ? `${text.slice(0, 57)}…` : text, type, text,
    about: `the Lisp value ${text.length > 80 ? `${text.slice(0, 77)}…` : text} (${reference(id)})`,
    commands: [
      { label: 'Inspect', doc: 'Look inside it', run: () => inspectLisp(id) },
      { label: 'Use at the prompt', doc: `Put ${reference(id)} at the prompt`, run: () => insertInComposer(reference(id)) },
      { label: 'Describe', doc: 'DESCRIBE it, at the prompt', run: () => insertInComposer(`(describe ${reference(id)})`) },
    ],
  };
}

/** A presentation of Lisp value ID, printed as TEXT. */
export function lispPresentation(text, id, type = '', { left = 'Inspect', doc = '' } = {}) {
  if (!id) return el('span', {}, text);
  return present(el('span', { 'data-doc': doc || type }, text), () => lispObject(text, id, type), { left });
}

async function lispInspection(id) {
  const data = await api('/api/lisp/inspect', { params: { id } });
  return {
    kind: 'Lisp object', title: data.title, type: data.type, text: data.title,
    about: `the Lisp value ${data.title} (${reference(data.id)})`,
    parts: data.parts.map(p => [p.label, p.id ? { lisp: { text: p.text, id: p.id } } : p.text]),
    commands: lispObject(data.title, data.id, data.type).commands.filter(c => c.label !== 'Inspect'),
    refresh: () => lispInspection(id),
  };
}

export async function inspectLisp(id) {
  try { inspect(await lispInspection(id)); } catch (err) { toast(err.message, 'red'); }
}

// ---------- the environment's objects ----------

const clip = (text, n = 60) => (text.length > n ? `${text.slice(0, n - 1)}…` : text);
const label = m => (m.role === 'user' ? `(C${m.turn})` : m.role === 'assistant' ? `(D${m.turn})` : m.role === 'error' ? `!! in (C${m.turn})` : m.role);

/** A tool call (state.activity's tool-call entry). */
export function toolCallObject(call) {
  const output = state.activity.find(a => a.kind === 'tool-output' && a.ref === call.id);
  const args = call.text.replace(new RegExp(`^${(call.tool || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:? ?`), '');
  return {
    kind: 'Tool call', title: `${call.tool || call.label}${args ? ` ${clip(args, 40)}` : ''}`, type: 'TOOL-CALL',
    text: output ? output.text : call.text,
    about: `the ${call.tool} call in (C${call.turn}) — ${clip(args, 120)}`,
    parts: [
      ['tool', call.tool ? { object: toolObject(call.tool) } : '—'],
      ['turn', `(C${call.turn})`],
      ['at', fmtClock(call.time)],
      ['state', output ? 'done' : 'running'],
      ['arguments', args || '—'],
      ['output', output ? output.text : '… still running'],
    ],
    commands: [{ label: 'Show in Activity', run: () => showPanel('activity') }],
  };
}

/** A message in the listener. */
export function messageObject(message) {
  const calls = state.activity.filter(a => a.turn === message.turn && a.kind === 'tool-call');
  return {
    kind: message.role === 'error' ? 'Error' : 'Message', title: `${label(message)} ${clip(message.text.replace(/\s+/g, ' '), 48)}`, type: message.role.toUpperCase(),
    text: message.text,
    about: `${label(message)} ("${clip(message.text.replace(/\s+/g, ' '), 100)}")`,
    parts: [
      ['role', message.role], ['turn', String(message.turn)], ['at', message.time ? fmtClock(message.time) : '—'],
      ['length', `${message.text.length} characters`],
      ...calls.map((c, i) => [i ? '' : `tool calls (${calls.length})`, { object: toolCallObject(c) }]),
      ['text', message.text],
    ],
    commands: message.role === 'user'
      ? [{ label: 'Edit and send again', doc: 'Put it back at the prompt', run: () => insertInComposer(message.text) }]
      : [],
  };
}

let tools = null;
async function toolInfo(name) {
  if (!tools) { try { tools = (await api('/api/tools')).tools; } catch (err) { tools = []; } }
  return tools.find(t => t.name === name);
}

/** A tool the agent can call. */
export function toolObject(name, info = null) {
  const object = {
    kind: 'Tool', title: name, type: 'TOOL', about: `the ${name} tool`,
    commands: [{ label: 'Call it yourself', doc: `Start a /call ${name}`, run: () => insertInComposer(`/call ${name} `) }],
    parts: info ? toolParts(info) : [['', '…']],
    refresh: async () => toolObject(name, await toolInfo(name)),
  };
  if (!info) toolInfo(name).then(found => { if (found) object.parts = toolParts(found); });
  return object;
}

function toolParts(info) {
  const props = info.parameters?.properties || {};
  const required = new Set(info.parameters?.required || []);
  return [
    ['description', info.description],
    ['effects', info.effects.join(', ') || 'none'],
    ['offered', info.enabled ? 'yes' : 'no (not in this session\'s tools)'],
    ['owner', info.owner || 'core'],
    ...Object.entries(props).map(([key, schema]) =>
      [`${key}${required.has(key) ? '' : '?'}`, `${schema.type || ''}${schema.description ? ` — ${schema.description}` : ''}`]),
  ];
}

/** A subagent (state.subagents). */
export function subagentObject(a) {
  const live = a.state === 'running' || a.state === 'queued';
  const t = now();
  return {
    kind: 'Agent', title: a.id, type: `AGENT ${a.state.toUpperCase()}`, about: `subagent ${a.id} (${a.description || a.state})`,
    text: a.description || a.id,
    parts: [
      ['state', a.state], ['task', a.description || '—'], ['doing', a.state === 'running' ? (a.activity || '—') : '—'],
      ['role', a.role || a.profile || '—'], ['model', a.model || '—'], ['depth', String(a.depth ?? 1)],
      ['started', a.started ? new Date(a.started * 1000).toLocaleTimeString() : 'not yet'],
      ['elapsed', a.started ? fmtDuration((a.finished || t) - a.started) : '—'],
      ['requests', String(a.requests ?? 0)], ['tool calls', String(a.tool_calls ?? 0)], ['tokens', fmtCount(a.tokens || 0)],
      ['tools', (a.tools || []).length ? el('span', {}, (a.tools || []).map(n => present(el('span', { class: 'tool-ref' }, n), () => toolObject(n)))) : '—'],
      ['note', a.note || '—'],
    ],
    commands: live ? [{
      label: 'Cancel', danger: true, doc: 'Stop this subagent and kill its process',
      run: async () => {
        try { await api('/api/subagents/cancel', { method: 'POST', body: { id: a.id } }); toast(`Cancelled ${a.id}`, 'orange'); } catch (err) { toast(err.message, 'red'); }
      },
    }] : [],
    refresh: async () => subagentObject((state.subagents || []).find(x => x.id === a.id) || a),
  };
}

/** The session: the main agent, its model and totals. */
export function sessionObject() {
  const s = state.session || {};
  const stats = state.stats || {};
  return {
    kind: 'Session', title: s.name || 'this session', type: 'SESSION', about: 'this session',
    parts: [
      ['state', state.planning ? 'planning' : state.thinking ? 'running' : 'waiting for input'],
      ['provider', stats.provider || '—'], ['model', stats.model || '—'], ['mode', s.mode || 'direct'],
      ['directory', s.cwd || '—'], ['user', `${s.user || ''}@${s.host || ''}`], ['Lisp', s.lisp || 'Common Lisp'],
      ['requests', String(stats.requests ?? 0)], ['tool calls', String(stats.tool_calls ?? 0)],
      ['tokens', fmtCount(stats.total_tokens || 0)], ['elapsed', fmtDuration(stats.elapsed_seconds || 0)],
      ['turns', String(state.turn || 0)], ['subagents', String((state.subagents || []).length)],
    ],
    commands: [{ label: 'Choose the model', doc: 'Alt-M', run: () => window.CLAgent?.openModelMenu?.() }],
    refresh: async () => sessionObject(),
  };
}

/** Run the prompt's /NAME with ARG; a failure is said, not thrown. */
const runCommand = (name, arg) => Promise.resolve()
  .then(() => clientCommands.get(name)?.run(arg))
  .catch(err => window.CLAgent?.toast(err.message, 'red'));

/** A file, by PATH (with what a listing knows: SIZE, MTIME). */
export function fileObject(path, { size, mtime, directory = false } = {}) {
  const name = path.replace(/\/$/, '').split('/').pop();
  return {
    kind: directory ? 'Directory' : 'File', title: name, type: directory ? 'DIRECTORY' : 'FILE', text: path,
    about: `@${path}`,
    parts: [['path', path], ['size', size != null ? `${size} bytes` : '—'], ['modified', mtime ? new Date(mtime * 1000).toLocaleString() : '—']],
    commands: [
      ...(directory
        ? [{ label: 'Terminal here', doc: '/term', run: () => runCommand('term', path) }]
        : [{ label: 'Edit in Lem', doc: '/edit', run: () => window.CLAgent?.editFile?.(path) },
           { label: 'Run in the terminal', doc: '/run: save, then run it by its type', run: () => runCommand('run', path) }]),
      { label: 'Put @path at the prompt', run: () => insertInComposer(`@${path} `) },
    ],
  };
}

/** The keys and mouse buttons, by where they work (Alt-H, /keys). */
export function keymapObject() {
  const group = (name, rows) => [[`;; ${name}`, ''], ...rows];
  return {
    kind: 'Keymap', title: 'cl-agent keys', type: 'KEYMAP',
    parts: [
      ...group('The mouse, on anything highlighted', [
        ['Left', 'its obvious command: inspect it, open it, select it'],
        ['Right', 'its menu: every command it has'],
        ['Alt-Left', 'a Lisp value: use it at the prompt'],
        ['Shift-Right', 'the browser\'s own menu']]),
      ...group('The prompt', [
        ['Enter', 'ask the agent / evaluate a (form) / run a /command — the prompt says which'],
        ['Alt-Enter', 'ask the agent, even if it looks like Lisp'],
        ['Shift-Enter', 'a new line'], ['Tab', 'complete /commands, @paths, (lisp-symbols'],
        ['↑ ↓', 'history'], ['Esc', 'abort the running turn, or break into a form'],
        [',form', 'evaluate anything, a bare symbol too'], ['/edit @file:line', 'open a file in Lem'],
        ['/mx command', 'run a Lem command (Tab completes its name)'], ['/keys', 'this']]),
      ...group('Anywhere', [
        ['Alt-L', 'the Lisp tab'], ['Alt-C', 'the Code tab'], ['Alt-S', 'the Sessions tab'],
        ['Alt-1…9', 'a side panel'], ['Alt-M', 'choose the model'], ['Alt-T', 'next theme'],
        ['Alt-H', 'inspect the keys'], ['Ctrl-\\', 'hide / show the side panes'],
        ['Alt-N', 'a new live session'], ['Alt-↑ Alt-↓', 'the previous / next live session'],
        ['/', 'to the prompt']]),
      ...group('The Lisp tab', [
        ['RET', 'evaluate a complete input'], ['C-c C-c', 'compile the form / interrupt'],
        ['C-x C-e', 'evaluate the form before point'], ['C-c C-k', 'compile and load the scratch buffer'],
        ['M-.', 'find a definition'], ['C-c C-d d', 'describe'], ['C-c I', 'inspect'],
        ['C-c C-z', 'scratch ⇄ REPL'], ['0–9 q c', 'in the debugger: a restart, abort, continue']]),
      ...group('Lem (the Code tab, and the scratch buffer in Lem)', [
        ['C-x C-f', 'visit a file'], ['M-x', 'run a command'], ['C-c C-a', 'put the region or form at the prompt, to ask about it']]),
      ...group('The Terminal tab (/term, /run)', [
        ['any key', 'the program\'s: Ctrl-C interrupts it, Alt is Meta'], ['Ctrl-Shift-A', 'put its last lines at the prompt, to ask about them'],
        ['Ctrl-Shift-P', 'back to the prompt'], ['⌘C / ⌘V', 'copy the mouse\'s selection, paste'], ['wheel, Shift-PageUp', 'its history']]),
    ],
  };
}

// ---------- the Inspect panel ----------

const stack = [];        // objects inspected, newest last

/** Show OBJECT in the Inspect panel (on top of what was there: ◀ Back). */
export function inspect(object) {
  stack.push(object);
  if (stack.length > 60) stack.shift();
  showPanel('inspector');
}

function partValue(value) {
  if (value instanceof Node) return value;
  if (value && value.object) return present(el('span', {}, value.object.title), () => value.object);
  if (value && value.lisp) return lispPresentation(value.lisp.text, value.lisp.id, value.lisp.type);
  const text = value == null ? '—' : String(value);
  return el('span', { class: text.length > 160 || text.includes('\n') ? 'inspector-text long' : 'inspector-text' }, text);
}

function renderInspector(target) {
  const top = stack[stack.length - 1];
  if (!top) {
    target.replaceChildren(el('div', { class: 'panel' }, el('div', { class: 'empty' },
      '; Nothing inspected yet.  Everything on the screen is an object: click a value to inspect it, or ',
      'right-click anything — a message label, a tool call, an agent, a file, a tool — for what you can do with it. ',
      'Alt-H inspects the keys.')));
    return;
  }
  const commands = commandsFor(top).filter(c => c.label !== 'Inspect');
  target.replaceChildren(el('div', { class: 'panel inspector' },
    el('div', { class: 'inspector-head' },
      el('div', { class: 'inspector-title' }, present(el('span', {}, top.title), () => top)),
      el('span', { class: 'chip fill-cyan' }, top.type || top.kind)),
    el('div', { class: 'inspector-actions' },
      el('button', {
        class: 'btn btn-small', type: 'button', disabled: stack.length < 2, 'data-doc': 'Back to the previous object',
        onclick: () => { stack.pop(); showPanel('inspector'); },
      }, '◀ Back'),
      top.refresh ? el('button', {
        class: 'btn btn-small', type: 'button', 'data-doc': 'Look again (it may have changed)',
        onclick: async () => { try { stack[stack.length - 1] = await top.refresh(); showPanel('inspector'); } catch (err) { toast(err.message, 'red'); } },
      }, '↻ Refresh') : '',
      commands.map(c => el('button', { class: `btn btn-small ${c.danger ? 'btn-danger' : ''}`, type: 'button', 'data-doc': c.doc || c.label, onclick: () => c.run(top) }, c.label)),
      el('span', { class: 'faint' }, `${stack.length} deep`)),
    top.parts?.length
      ? el('table', { class: 'inspector-parts' }, top.parts.map(([label, value]) => (label.startsWith(';;')
        ? el('tr', { class: 'inspector-group' }, el('th', { colspan: '2' }, label))
        : el('tr', {}, el('th', { title: label }, label), el('td', {}, partValue(value))))))
      : el('div', { class: 'empty' }, '; No parts.')));
}

registerPanel({
  id: 'inspector', title: 'Inspect', color: 'cyan', order: 15,
  doc: 'The inspector: the parts of whatever you clicked or chose Inspect for',
  events: [],
  render: renderInspector,
});
