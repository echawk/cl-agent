// agents.js -- the Agents panel: the agents as processes, then a
// graphical overview of subagents.
//
//   * process table    Genera's Peek: one row per agent, the main one (λ)
//                      first -- id, a state word (RUN WAIT DONE FAIL KILL),
//                      elapsed time, and what it is doing now
//                      (its caption tallies them, with tools and tokens)
//   * map              the main agent in the middle, each subagent around it;
//                      node size grows with tokens, running links animate
//   * tree + timeline  one row per subagent: its place under the main agent
//                      on the left, a Gantt bar on the right (hatched while
//                      queued, striped while running), on a shared time axis
//   Every row and node is a presentation (objects.js): click inspects the
//   agent in the Inspect panel (Cancel is there, and in its right-button menu).
//
// Data: state.subagents (server "subagents" events: every subagent this
// session started, finished ones included) and state.thinking/planning for
// the main agent.

import { state, on, el, registerPanel, fmtDuration, fmtCount, now, frameThrottle, storage, store } from './core.js';
import { present, inspect, subagentObject, sessionObject } from './objects.js';

const SVG = 'http://www.w3.org/2000/svg';
const GLYPH = { queued: '○', running: '●', succeeded: '✓', failed: '✗', cancelled: '⊘' };
const ORDER = ['running', 'queued', 'failed', 'cancelled', 'succeeded'];
const WORD = { queued: 'WAIT', running: 'RUN', succeeded: 'DONE', failed: 'FAIL', cancelled: 'KILL' };
let selected = null;
let host = null;

function svg(tag, attrs = {}, ...children) {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  node.append(...children);
  return node;
}

function counts(items) {
  const c = { queued: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0 };
  for (const a of items) c[a.state] = (c[a.state] || 0) + 1;
  return c;
}

// An agent is an object: clicking one inspects it (objects.js).
function select(id) {
  selected = id;
  const a = (state.subagents || []).find(x => x.id === id);
  if (a) inspect(subagentObject(a));
}

// ---------- constellation ----------

function constellation(items) {
  const width = 400;
  const height = items.length > 12 ? 300 : 230;
  const cx = width / 2;
  const cy = height / 2;
  const busy = state.thinking || state.planning;
  const maxTokens = Math.max(1, ...items.map(a => a.tokens || 0));
  const rings = items.length > 12 ? [items.slice(0, Math.ceil(items.length / 2)), items.slice(Math.ceil(items.length / 2))] : [items];
  const edges = [];
  const nodes = [];
  rings.forEach((ring, r) => {
    const radius = rings.length === 1 ? Math.min(cx, cy) - 30 : (r === 0 ? 70 : Math.min(cx, cy) - 26);
    ring.forEach((a, i) => {
      const angle = (i / ring.length) * Math.PI * 2 - Math.PI / 2 + r * 0.35;
      const x = cx + Math.cos(angle) * radius * (rings.length === 1 ? 1.45 : 1.5);
      const y = cy + Math.sin(angle) * radius;
      const size = 9 + 9 * Math.sqrt((a.tokens || 0) / maxTokens);
      edges.push(svg('line', { class: `edge ${a.state === 'running' ? 'running' : ''}`, x1: cx, y1: cy, x2: x, y2: y }));
      const group = svg('g', { onclick: () => select(a.id), style: 'cursor:pointer' },
        svg('title', {}, `${a.id} · ${a.state}${a.description ? ` · ${a.description}` : ''}`));
      if (a.state === 'running') group.append(svg('circle', { class: 'pulse', cx: x, cy: y, r: size }));
      group.append(svg('circle', { class: `node state-${a.state} ${selected === a.id ? 'selected' : ''}`, cx: x, cy: y, r: size }));
      group.append(svg('text', { class: 'node-label', x, y: y + size + 11, 'text-anchor': 'middle' }, a.id));
      nodes.push(group);
    });
  });
  const root = svg('g', {},
    busy ? svg('rect', { class: 'pulse', x: cx - 20, y: cy - 20, width: 40, height: 40 }) : '',
    svg('rect', { class: `node root ${busy ? 'busy' : ''}`, x: cx - 20, y: cy - 20, width: 40, height: 40 }),
    svg('text', { x: cx, y: cy + 7, 'text-anchor': 'middle', style: 'font: 700 20px var(--font); fill: var(--on-yellow)' }, 'λ'));
  return svg('svg', { class: 'constellation', viewBox: `0 0 ${width} ${height}`, role: 'img',
    'aria-label': `Main agent with ${items.length} subagents`, 'data-doc': 'Click a node: show that subagent' },
  ...edges, root, ...nodes);
}

// ---------- process table ----------

function mainDoing() {
  if (!state.thinking && !state.planning) return state.connected === false ? 'offline' : 'waiting for input';
  const last = [...(state.activity || [])].reverse().find(a => a.turn === state.turn && a.kind !== 'event');
  return last ? last.label.toLowerCase() : state.planning ? 'planning' : 'thinking';
}

function processTable(items) {
  const t = now();
  const busy = state.thinking || state.planning;
  const row = ({ id, glyph, word, stateClass, time, doing, model, describe, chosen }) => present(el('tr', {
    class: `proc ${stateClass} ${chosen ? 'selected' : ''}`,
    'data-doc': `${doing}${model ? ` · ${model}` : ''}`,
  },
  el('td', { class: 'proc-id' }, el('span', { class: 'glyph-box' }, glyph), id),
  el('td', { class: 'proc-state' }, word),
  el('td', { class: 'proc-time' }, time),
  el('td', { class: 'proc-doing' }, doing)), describe);
  const rows = [row({
    id: 'main', glyph: 'λ', word: state.planning ? 'PLAN' : busy ? 'RUN' : 'IDLE',
    stateClass: busy ? 'state-running' : 'state-idle', time: state.stats ? fmtDuration(state.stats.elapsed_seconds || 0) : '',
    doing: mainDoing(), model: state.stats?.model, describe: sessionObject,
  })];
  for (const a of items) {
    rows.push(row({
      id: a.id, glyph: GLYPH[a.state] || '?', word: WORD[a.state] || a.state.toUpperCase(), stateClass: `state-${a.state}`,
      time: a.started ? fmtDuration((a.finished || t) - a.started) : '—',
      doing: a.state === 'running' ? (a.activity || a.description || 'working')
        : a.state === 'queued' ? `waiting · ${a.description || ''}`
          : `${a.tool_calls || 0} tool${a.tool_calls === 1 ? '' : 's'} · ${a.description || a.note || ''}`,
      model: a.model, describe: () => subagentObject(a), chosen: selected === a.id,
    }));
  }
  const c = counts(items);
  const tokens = items.reduce((s, a) => s + (a.tokens || 0), 0);
  const tools = items.reduce((s, a) => s + (a.tool_calls || 0), 0);
  const tally = [['RUN', c.running], ['WAIT', c.queued], ['DONE', c.succeeded], ['FAIL', c.failed], ['KILL', c.cancelled]]
    .filter(([, n]) => n).map(([w, n]) => `${n} ${w}`).join(' · ');
  return el('table', { class: 'procs', 'aria-label': 'Agents' },
    el('caption', {}, `;; ${items.length ? `${tally} · ${fmtCount(tools)} tools · ${fmtCount(tokens)} tok` : 'no subagents yet'}`),
    el('thead', {}, el('tr', {}, ['agent', 'state', 'time', 'doing'].map(h => el('th', {}, h)))),
    el('tbody', {}, rows));
}

// ---------- tree + timeline ----------

function niceStep(span) {
  const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200];
  return steps.find(s => span / s <= 5) || 14400;
}

function gantt(items) {
  const t = now();
  const begin = Math.min(...items.map(a => a.created || a.started || t));
  const end = Math.max(t, ...items.map(a => a.finished || t));
  const span = Math.max(end - begin, 10);
  const pct = x => `${((x - begin) / span) * 100}%`;
  const step = niceStep(span);
  const ticks = [];
  for (let s = step; s < span; s += step) ticks.push(s);

  const axis = el('div', { class: 'gantt-axis' },
    el('div', { class: 'axis-label' }, 'agent'),
    el('div', { class: 'axis-track' }, ticks.map(s => el('span', { class: 'tick', style: { left: pct(begin + s) } }, `+${fmtDuration(s)}`))));

  const rootRow = el('div', { class: `gantt-row root-row ${state.thinking || state.planning ? 'state-running' : 'state-succeeded'}` },
    el('div', { class: 'gantt-name' },
      el('span', { class: 'glyph-box', style: { background: 'var(--yellow)', color: 'var(--on-yellow)' } }, 'λ'),
      el('span', { class: 'gantt-id' }, 'main'),
      el('span', { class: 'gantt-role' }, state.planning ? 'planning' : state.thinking ? 'running' : 'idle')),
    el('div', { class: 'gantt-track' }, ticks.map(s => el('span', { class: 'gantt-grid', style: { left: pct(begin + s) } }))));

  const rows = items.map(a => {
    const created = a.created || a.started || t;
    const started = a.started;
    const finished = a.finished || t;
    const bars = [];
    if (started && started > created) bars.push(el('span', { class: 'bar wait', style: { left: pct(created), width: pct(begin + (started - created)) } }));
    if (!started) bars.push(el('span', { class: 'bar wait', style: { left: pct(created), width: pct(begin + (finished - created)) } }));
    if (started) bars.push(el('span', { class: 'bar run', style: { left: pct(started), width: pct(begin + Math.max(finished - started, 0)) } }));
    const elapsed = started ? fmtDuration(finished - started) : 'waiting';
    const summary = `${elapsed} · ${a.tool_calls} tool${a.tool_calls === 1 ? '' : 's'}`;
    // Label the bar's end when there is room; the row's name cell always has it too.
    const labelLeft = ((Math.min(finished, end) - begin) / span) * 100;
    if (labelLeft < 62) bars.push(el('span', { class: 'bar-label', style: { left: `calc(${labelLeft}% + 12px)` } }, summary));
    return el('div', {
      class: `gantt-row state-${a.state} ${selected === a.id ? 'selected' : ''}`,
      onclick: () => select(a.id),
      'data-doc': `${a.id}: ${a.description || a.state}. Click: details`,
    },
    el('div', { class: 'gantt-name' },
      el('span', { class: 'branch' }),
      el('span', { class: 'glyph-box' }, GLYPH[a.state] || '?'),
      el('span', { class: 'gantt-id' }, a.id),
      el('span', { class: 'gantt-role', title: summary }, `${a.role || a.profile || a.state} · ${elapsed}`)),
    el('div', { class: 'gantt-track' },
      ticks.map(s => el('span', { class: 'gantt-grid', style: { left: pct(begin + s) } })),
      bars));
  });
  return el('div', { class: 'gantt' }, axis, rootRow, rows);
}

// ---------- panel ----------

function sorted(items) {
  return [...items].sort((a, b) => (ORDER.indexOf(a.state) - ORDER.indexOf(b.state)) || ((a.created || 0) - (b.created || 0)));
}

let mapOpen = storage('agents-map', true);

function render(target) {
  host = target;
  const items = state.subagents || [];
  const map = el('details', { class: 'agents-map', open: mapOpen || undefined },
    el('summary', { 'data-doc': 'Show or hide the map of subagents around the main agent' }, ';; Map'),
    constellation(sorted(items)));
  map.addEventListener('toggle', () => { mapOpen = map.open; store('agents-map', mapOpen); });
  const body = el('div', { class: 'panel' },
    processTable(sorted(items)),
    items.length
      ? [map, el('div', { class: 'panel-section' }, el('h3', {}, 'Tree & timeline'), gantt(sorted(items)))]
      : el('div', { class: 'faint agents-hint' }, '; When the agent delegates work (start-subagent), each child gets a row here, then a map and a timeline. Click a row to inspect it; right-click for its menu.'));
  target.replaceChildren(body);
}

const rerender = frameThrottle(() => { if (host?.isConnected) render(host); });

registerPanel({
  id: 'agents',
  title: 'Agents',
  color: 'green',
  order: 10,
  doc: 'A live map and timeline of the subagents this session has started',
  badge: s => (s.subagents || []).filter(a => a.state === 'running' || a.state === 'queued').length || '',
  render,
  events: ['subagents', 'status', 'state'],
});

// Running bars grow and elapsed times count while the panel is open.
setInterval(() => {
  if (host?.isConnected && (state.subagents || []).some(a => a.state === 'running' || a.state === 'queued')) rerender();
}, 1000);
on('subagents', rerender);
