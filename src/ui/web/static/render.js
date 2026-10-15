// render.js -- the Listener pane: the conversation, Macsyma-style.
//
// Each user input is (C n) and each reply (D n), grouped in a <section
// class="turn" data-turn="n">.  Tool calls made during turn n show as one
// collapsible ";; 3 tool calls" line inside that section (details live in
// the Activity panel too).  System text is shown inline only when the
// server marks it `inline` (output of a slash command run while idle).
//
// Customizing: CLAgent.registerRenderer(role, fn) renders a role yourself;
// CLAgent.registerMessageDecorator(fn) adjusts every entry after rendering.

import {
  state, on, el, messageRenderers, messageDecorators, copyText, frameThrottle, turnExtras,
} from './core.js';
import { present, messageObject, toolCallObject } from './objects.js';

const listener = () => document.getElementById('listener');
const jump = () => document.getElementById('jump');

// ---------- sanitizing server-rendered Markdown ----------

const ALLOWED_TAGS = new Set(['A', 'BLOCKQUOTE', 'BR', 'CODE', 'DEL', 'EM', 'H1', 'H2', 'H3', 'H4', 'H5',
  'H6', 'HR', 'LI', 'OL', 'P', 'PRE', 'S', 'SPAN', 'STRONG', 'TABLE', 'TBODY', 'TD', 'TH', 'THEAD', 'TR', 'UL']);

/** Keep only allowlisted tags, safe link targets, code language classes and
 *  the sx-* token classes of code Lem highlighted (lem/highlight.lisp). */
export function sanitize(html) {
  const box = document.createElement('template');
  box.innerHTML = html;
  for (const node of [...box.content.querySelectorAll('*')]) {
    if (!ALLOWED_TAGS.has(node.tagName)) {
      node.replaceWith(document.createTextNode(node.textContent || ''));
      continue;
    }
    for (const attr of [...node.attributes]) {
      const keepLink = node.tagName === 'A' && attr.name === 'href' && /^(https?:|mailto:|#)/i.test(attr.value);
      const keepLanguage = node.tagName === 'CODE' && attr.name === 'class' && /^language-[\w+#.-]+$/.test(attr.value);
      const keepToken = node.tagName === 'SPAN' && attr.name === 'class' && /^sx-[a-z0-9-]+$/.test(attr.value);
      if (!keepLink && !keepLanguage && !keepToken) node.removeAttribute(attr.name);
    }
    if (node.tagName === 'A') { node.target = '_blank'; node.rel = 'noopener noreferrer'; }
  }
  return box.innerHTML;
}

function decorateCodeBlocks(container) {
  for (const pre of container.querySelectorAll('pre')) {
    if (pre.querySelector('.code-head')) continue;
    const code = pre.querySelector('code');
    const language = (code?.className.match(/language-([\w+#.-]+)/) || [])[1] || 'text';
    const copy = el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Copy this code block' }, 'Copy');
    copy.addEventListener('click', () => copyText((code || pre).innerText, copy));
    pre.prepend(el('div', { class: 'code-head' }, el('span', {}, language), copy));
  }
}

function typesetMath(node) {
  const mathjax = window.MathJax;
  if (mathjax?.typesetPromise && /\$|\\\[|\\\(/.test(node.textContent)) {
    mathjax.typesetPromise([node]).catch(() => {});
  }
}

// ---------- entries ----------

function label(message) {
  switch (message.role) {
    case 'user': return `(C${message.turn})`;
    case 'assistant': return `(D${message.turn})`;
    case 'error': return '!!';
    default: return ';;;';
  }
}

/** Whether MESSAGE appears in the listener at all. */
export function visible(message) {
  if (message.role === 'tool') return false;          // shown via the tools line
  if (message.role === 'system') return message.inline;
  return true;
}

function entryShell(message, extraClass = '') {
  // The label is the message, presented: click inspects it, right-click has its menu.
  const tag = el('div', { class: 'label' }, label(message));
  if (message.id !== 'live' && ['user', 'assistant', 'error'].includes(message.role)) present(tag, () => messageObject(message));
  return el('article', {
    class: `entry ${message.role} ${extraClass}`.trim(),
    dataset: { id: message.id, turn: message.turn },
  }, tag, el('div', { class: 'body' }));
}

function copyButton(text, doc = 'Copy this as text') {
  const button = el('button', { class: 'btn btn-small', type: 'button', 'data-doc': doc }, 'Copy');
  button.addEventListener('click', () => copyText(text, button));
  return el('div', { class: 'tools' }, button);
}

export function renderMessage(message) {
  const custom = messageRenderers.get(message.role);
  let node;
  if (custom) {
    node = entryShell(message);
    custom(message, node.querySelector('.body'), node);
  } else if (message.role === 'assistant') {
    node = entryShell(message);
    const body = node.querySelector('.body');
    if (message.html) {
      body.classList.add('markdown');
      body.innerHTML = sanitize(message.html);
      decorateCodeBlocks(body);
    } else {
      body.style.whiteSpace = 'pre-wrap';
      body.textContent = message.text;
    }
    node.append(copyButton(message.text, 'Copy the Markdown source of this reply'));
  } else if (message.role === 'compaction') {
    node = el('article', { class: 'entry system', dataset: { id: message.id, turn: message.turn } },
      el('div', { class: 'label' }, '§'),
      el('details', { class: 'body compaction' },
        el('summary', { 'data-doc': 'Click: show the summary that replaced older context' },
          'Context compacted · view continuity summary'),
        el('pre', {}, message.text)));
  } else {
    const command = message.role === 'user' && message.text.startsWith('/');
    node = entryShell(message, command ? 'command' : '');
    node.querySelector('.body').textContent = message.text;
    if (message.role !== 'user') node.append(copyButton(message.text));
  }
  for (const decorate of messageDecorators) {
    try { decorate(node, message); } catch (err) { console.error('[cl-agent] decorator failed', err); }
  }
  return node;
}

// ---------- turns ----------


function turnSection(turn) {
  const root = listener();
  let section = root.querySelector(`:scope > section.turn[data-turn="${turn}"]`);
  if (!section) {
    section = el('section', { class: 'turn', dataset: { turn } });
    if (clearedThrough >= turn) section.classList.add('cleared');
    const later = [...root.querySelectorAll(':scope > section.turn')].find(s => +s.dataset.turn > turn);
    const live = root.querySelector(':scope > #live');
    root.insertBefore(section, later || live || null);
  }
  return section;
}

function summarizeTools(calls) {
  const counts = new Map();
  for (const call of calls) counts.set(call.tool, (counts.get(call.tool) || 0) + 1);
  return [...counts].map(([name, n]) => (n > 1 ? `${name} ×${n}` : name)).join(' · ');
}

function renderCall(call, output) {
  return el('div', { class: 'call' },
    el('div', { class: 'call-head' },
      present(el('span', { class: 'call-name' }, call.tool || call.label), () => toolCallObject(call)),
      el('span', { class: 'call-args' }, call.text.replace(new RegExp(`^${(call.tool || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:? ?`), ''))),
    output ? el('pre', { class: 'call-output' }, output.text)
      : el('div', { class: 'faint' }, '… running'));
}

/** (Re)draw the ";; N tool calls" line of TURN from state.activity. */
export function renderToolsLine(turn) {
  const entries = state.activity.filter(a => a.turn === turn && (a.kind === 'tool-call' || a.kind === 'tool-output'));
  const calls = entries.filter(a => a.kind === 'tool-call');
  const section = turnSection(turn);
  const existing = section.querySelector(':scope > .tools-line');
  if (!calls.length) { existing?.remove(); return; }
  const outputs = new Map(entries.filter(a => a.kind === 'tool-output' && a.ref).map(a => [a.ref, a]));
  const wasOpen = existing?.open;
  const line = el('details', { class: 'tools-line' },
    el('summary', { 'data-doc': 'Click: show each tool call and its output' },
      `;; ${calls.length} tool call${calls.length === 1 ? '' : 's'} — ${summarizeTools(calls)}`,
      el('span', { class: 'tool-dots' }, calls.map(call =>
        el('i', { class: `tool-dot ${outputs.has(call.id) ? '' : 'running'}` })))),
    el('div', { class: 'tools-list' }, calls.map(call => renderCall(call, outputs.get(call.id)))));
  line.open = !!wasOpen;
  if (existing) existing.replaceWith(line);
  else {
    const user = section.querySelector(':scope > .entry.user');
    if (user) user.after(line); else section.prepend(line);
  }
}

// ---------- the live entry: streaming text or the run indicator ----------

function renderLive() {
  const root = listener();
  let live = root.querySelector(':scope > #live');
  const busy = state.thinking || state.planning;
  if (!state.pending && !busy) { live?.remove(); return; }
  if (!live) {
    live = el('div', { id: 'live' });
    root.append(live);
  }
  const turn = state.turn || 0;
  if (state.pending) {
    const entry = entryShell({ role: 'assistant', turn, id: 'live' }, 'pending');
    entry.querySelector('.body').textContent = state.pending;
    live.replaceChildren(entry);
  } else {
    const last = [...state.activity].reverse().find(a => a.turn === turn && a.kind !== 'event');
    const doing = state.planning ? 'Plan' : 'Run';
    const entry = entryShell({ role: 'assistant', turn, id: 'live' });
    entry.querySelector('.body').append(el('span', { class: `run-indicator ${state.planning ? 'planning' : ''}` },
      el('span', { class: 'run-bar' }), el('strong', {}, doing),
      el('span', {}, last ? last.label.toLowerCase() : 'thinking…')));
    live.replaceChildren(entry);
  }
}

// ---------- scrolling ----------

function nearBottom() {
  const root = listener();
  return root.scrollHeight - root.scrollTop - root.clientHeight < 60;
}

let follow = true;

export function scrollToLatest() {
  const root = listener();
  root.scrollTop = root.scrollHeight;
  follow = true;
  jump().hidden = true;
}

function afterChange() {
  if (follow) scrollToLatest();
  else jump().hidden = false;
}

// ---------- clearing (Genera's "Clear Window") ----------

let clearedThrough = -1;

export function clearListener() {
  clearedThrough = state.turn;
  for (const section of listener().querySelectorAll('section.turn')) section.classList.add('cleared');
  renderHerald();
}

// ---------- full render ----------

function renderHerald() {
  const root = listener();
  root.querySelector(':scope > .herald')?.remove();
  const shown = state.messages.some(m => visible(m) && m.turn > clearedThrough)
    || root.querySelector(':scope > section.turn:not(.cleared) .listener-form');
  if (shown || state.pending || state.thinking || state.planning) return;
  const session = state.session || {};
  root.prepend(el('div', { class: 'herald' },
    el('pre', { html: [
      '<span class="accent-yellow">  ╻</span>',
      '<span class="accent-yellow">  ┗┓</span>    <span class="accent-pink">cl-agent</span> listener',
      '<span class="accent-yellow">  ┏┻┓</span>   a self-extending Lisp agent',
      '<span class="accent-yellow">  ╹ ╹</span>',
    ].join('\n') }),
    el('div', {}, `${session.lisp || 'Common Lisp'} · ${session.user || ''}@${session.host || 'localhost'} · ${session.cwd || ''}`),
    el('p', {}, 'Type a request and press ', el('kbd', {}, 'Enter'), '. A Lisp form — ', el('code', {}, '(+ 1 2)'),
      ' — is evaluated here in the image instead (click its value to inspect it); ', el('code', {}, '/edit @file'),
      ' opens a file in Lem. ', el('kbd', {}, 'Tab'), ' completes /commands, @paths and (lisp-symbols; ',
      el('kbd', {}, '↑'), ' recalls history; ', el('kbd', {}, 'Esc'), ' aborts a running turn.'),
    el('p', {}, 'Everything on the screen is an object: click one to inspect it, right-click it for its commands. ',
      el('kbd', {}, 'Alt-H'), ' inspects the keys.'),
    el('p', {}, 'Ask the agent to change this page itself ("make the labels green", "add a panel that shows git status") — see the ',
      el('a', { href: '#', onclick: e => { e.preventDefault(); window.CLAgent?.showPanel('ui'); } }, 'UI panel'), '.')));
}

export function renderAll() {
  const root = listener();
  follow = nearBottom() || follow;
  root.replaceChildren();
  for (const message of state.messages) {
    if (visible(message)) turnSection(message.turn).append(renderMessage(message));
  }
  const turns = new Set(state.activity.filter(a => a.kind === 'tool-call').map(a => a.turn));
  for (const turn of turns) renderToolsLine(turn);
  for (const extra of turnExtras) {
    try { extra(turnSection); } catch (err) { console.error('[cl-agent] listener extra failed', err); }
  }
  renderLive();
  renderHerald();
  typesetMath(root);
  afterChange();
}

// ---------- incremental updates ----------

const liveUpdate = frameThrottle(() => { renderLive(); afterChange(); });
const toolLineUpdates = new Set();
const flushToolLines = frameThrottle(() => {
  for (const turn of toolLineUpdates) renderToolsLine(turn);
  toolLineUpdates.clear();
  renderLive();
  afterChange();
});

export function install() {
  listener().addEventListener('scroll', () => {
    follow = nearBottom();
    if (follow) jump().hidden = true;
  });
  jump().addEventListener('click', scrollToLatest);

  on('state', renderAll);
  on('rerender', renderAll);
  on('message', ev => {
    const message = ev.message;
    if (!visible(message)) return;
    follow = follow || nearBottom();
    listener().querySelector(':scope > .herald')?.remove();
    const node = renderMessage(message);
    turnSection(message.turn).append(node);
    if (message.role === 'assistant') typesetMath(node);
    if (message.role === 'user') follow = true;
    renderLive();
    afterChange();
  });
  on('delta', liveUpdate);
  on('pending', liveUpdate);
  on('status', liveUpdate);
  on('activity', ev => {
    if (ev.entry.kind === 'tool-call' || ev.entry.kind === 'tool-output') {
      toolLineUpdates.add(ev.entry.turn);
      flushToolLines();
    } else if (state.thinking || state.planning) {
      liveUpdate();
    }
  });
}
