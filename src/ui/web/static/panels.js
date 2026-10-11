// panels.js -- the side pane: a tab per registered panel, plus the
// built-in Activity, Tools and UI panels (Agents lives in agents.js).
//
// A panel is {id, title, color, order, doc, badge(state), render(el, state),
// update(el, ev)?, events?}.  render draws the whole panel; it runs when the
// panel is shown and after each event named in `events` (default: every
// change).  update, if given, handles those events incrementally instead.
// Register your own with CLAgent.registerPanel -- see EXTENDING.md.

import {
  state, on, el, api, panels, registerPanel, copyText, fmtClock, storage, store, setTheme, theme,
  frameThrottle, boot,
} from './core.js';
import { insert } from './composer.js';

const $ = id => document.getElementById(id);
let active = storage('panel', 'agents');

// ---------- the tab host ----------

function ordered() {
  return [...panels.values()].sort((a, b) => (a.order - b.order) || a.title.localeCompare(b.title));
}

function renderTabs() {
  const list = ordered();
  if (!panels.has(active) && list.length) active = list[0].id;
  $('tabs').replaceChildren(...list.map((panel, i) => {
    const badge = panel.badge ? panel.badge(state) : '';
    return el('button', {
      class: `tab ${panel.id === active ? 'active' : ''}`,
      type: 'button', role: 'tab',
      style: { '--tab-color': `var(--${panel.color})`, '--tab-on': `var(--on-${panel.color})` },
      'data-doc': `${panel.doc || panel.title}${i < 9 ? ` (Alt-${i + 1})` : ''}`,
      onclick: () => showPanel(panel.id),
    }, panel.title, badge ? el('span', { class: 'badge' }, badge) : '');
  }));
  const current = panels.get(active);
  if (current) {
    $('side').style.setProperty('--pane-color', `var(--${current.color})`);
  }
}

function renderActive(ev = null) {
  const panel = panels.get(active);
  const body = $('panel-body');
  if (!panel) { body.replaceChildren(); return; }
  if (body.dataset.panel !== panel.id) {
    body.dataset.panel = panel.id;
    body.scrollTop = 0;
    ev = null;
  }
  try {
    if (ev && panel.update) panel.update(body, ev);
    else panel.render(body, state, ev);
  } catch (err) {
    console.error(`[cl-agent] panel ${panel.id} failed`, err);
    body.replaceChildren(el('div', { class: 'panel' }, el('div', { class: 'empty' }, `Panel "${panel.title}" failed: ${err.message}`)));
  }
}

export function showPanel(id) {
  if (!panels.has(id)) return;
  active = id;
  store('panel', id);
  $('desk').classList.remove('side-hidden');
  renderTabs();
  renderActive();
}

export function panelIds() { return ordered().map(p => p.id); }

const tabsUpdate = frameThrottle(renderTabs);

export function install() {
  on('panels', () => { renderTabs(); renderActive(); });
  on('state', () => { renderTabs(); renderActive(); });
  on('change', ev => {
    tabsUpdate();
    const panel = panels.get(active);
    if (!panel || !ev) return;
    if (!panel.events || panel.events.includes(ev.type)) renderActive(ev);
  });
  renderTabs();
  renderActive();
}

// ---------- Activity ----------

const KINDS = [
  ['tools', 'Tools', k => k === 'tool-call' || k === 'tool-output'],
  ['status', 'Status', k => k === 'system' || k === 'error' || k === 'narration'],
  ['plan', 'Plan', k => k === 'planning'],
  ['agents', 'Agents', k => k === 'subagent'],
  ['events', 'Events', k => k === 'event'],
];
const KIND_COLOR = {
  'tool-call': 'violet', 'tool-output': 'paper', system: 'ink', error: 'red', narration: 'cyan',
  planning: 'orange', subagent: 'green', event: 'paper',
};
let filters = new Set(storage('activity-filters', ['tools', 'status', 'plan', 'agents']));
let query = '';

function shown(entry) {
  if (entry.kind === 'tool-output' && entry.ref) return false;   // nested under its call
  const group = KINDS.find(([, , test]) => test(entry.kind));
  if (group && !filters.has(group[0])) return false;
  if (query) {
    const q = query.toLowerCase();
    return entry.label.toLowerCase().includes(q) || entry.text.toLowerCase().includes(q);
  }
  return true;
}

function clampedBody(text) {
  const body = el('pre', { class: 'act-body' }, text);
  const long = text.split('\n').length > 7 || text.length > 700;
  if (!long) return [body];
  body.classList.add('clamped');
  const more = el('button', { class: 'btn btn-small more', type: 'button' }, 'more');
  more.addEventListener('click', () => {
    const open = body.classList.toggle('clamped');
    more.textContent = open ? 'more' : 'less';
  });
  return [body, more];
}

function activityEntry(entry, outputs) {
  const copy = el('button', { class: 'btn btn-small', type: 'button', 'data-doc': 'Copy this entry' }, 'Copy');
  copy.addEventListener('click', () => copyText(entry.text, copy));
  const output = outputs.get(entry.id);
  return el('div', { class: 'act', dataset: { id: entry.id } },
    el('div', { class: 'act-head' },
      el('span', { class: `chip fill-${KIND_COLOR[entry.kind] || 'paper'}` }, entry.kind.replace('-', ' ')),
      el('span', { class: 'act-label' }, entry.label),
      el('span', { class: 'act-time' }, fmtClock(entry.time)),
      copy),
    clampedBody(entry.text),
    entry.kind === 'tool-call'
      ? el('div', { class: 'output' }, el('div', { class: 'output-head' }, output ? 'output' : 'running…'),
        output ? clampedBody(output.text) : '')
      : '');
}

let activityHost = null;
let lastTurn = null;

function appendActivity(list, entry, outputs) {
  if (!shown(entry)) return;
  if (entry.turn !== lastTurn) {
    lastTurn = entry.turn;
    list.append(el('div', { class: 'turn-divider' }, entry.turn ? `(C${entry.turn})` : 'startup'));
  }
  list.append(activityEntry(entry, outputs));
}

function outputsByCall() {
  return new Map(state.activity.filter(a => a.kind === 'tool-output' && a.ref).map(a => [a.ref, a]));
}

function pinnedToBottom(scroller) {
  return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 40;
}

function renderActivity(target) {
  activityHost = target;
  lastTurn = null;
  const search = el('input', { class: 'field', type: 'search', placeholder: 'Filter activity…', value: query });
  search.addEventListener('input', () => { query = search.value; renderList(); });
  const chips = el('div', { class: 'filters' }, KINDS.map(([key, title]) => el('span', {
    class: `chip ${filters.has(key) ? 'on' : ''}`,
    'data-doc': `Show or hide ${title.toLowerCase()} entries`,
    onclick: () => {
      if (filters.has(key)) filters.delete(key); else filters.add(key);
      store('activity-filters', [...filters]);
      renderActivity(target);
    },
  }, title)));
  const list = el('div', { class: 'activity-list', id: 'activity-list' });
  function renderList() {
    lastTurn = null;
    const outputs = outputsByCall();
    list.replaceChildren();
    for (const entry of state.activity) appendActivity(list, entry, outputs);
    if (!list.children.length) list.append(el('div', { class: 'empty' }, 'Tool calls, plans, status and subagent changes appear here as the agent works.'));
  }
  renderList();
  target.replaceChildren(el('div', { class: 'panel' }, el('div', { class: 'panel-section' }, chips, search), list));
  target.scrollTop = target.scrollHeight;
}

function updateActivity(target, ev) {
  if (ev.type !== 'activity') { if (ev.type === 'state') renderActivity(target); return; }
  const list = target.querySelector('#activity-list');
  if (!list) { renderActivity(target); return; }
  const pinned = pinnedToBottom(target);
  list.querySelector(':scope > .empty')?.remove();
  const entry = ev.entry;
  if (entry.kind === 'tool-output' && entry.ref) {
    const call = list.querySelector(`.act[data-id="${entry.ref}"]`);
    if (call) call.replaceWith(activityEntry(state.activity.find(a => a.id === entry.ref), outputsByCall()));
  } else {
    appendActivity(list, entry, outputsByCall());
  }
  if (pinned) target.scrollTop = target.scrollHeight;
}

registerPanel({
  id: 'activity', title: 'Activity', color: 'violet', order: 20,
  doc: 'Everything the agent did: tool calls with their output, plans, status',
  render: renderActivity, update: updateActivity, events: ['activity', 'state'],
});

// ---------- Tools ----------

let toolCache = null;
let toolQuery = '';
const EFFECT_COLOR = { 'read-workspace': 'green', 'write-workspace': 'orange', process: 'violet', 'self-modify': 'pink' };

async function loadTools(target) {
  try { toolCache = (await api('/api/tools')).tools; } catch (err) { toolCache = []; }
  if (target.isConnected && target.dataset.panel === 'tools') renderTools(target);
}

function renderTools(target) {
  if (!toolCache) {
    target.replaceChildren(el('div', { class: 'panel' }, el('div', { class: 'empty' }, 'Loading tools…')));
    loadTools(target);
    return;
  }
  const search = el('input', { class: 'field', type: 'search', placeholder: 'Filter tools…', value: toolQuery });
  const list = el('div', {});
  const draw = () => {
    const q = toolQuery.toLowerCase();
    const tools = toolCache.filter(t => !q || t.name.includes(q) || t.description.toLowerCase().includes(q));
    list.replaceChildren(...tools.map(tool => {
      const card = el('div', { class: `tool-card ${tool.enabled ? '' : 'disabled'}` },
        el('div', { class: 'tool-head' },
          el('span', {
            class: 'tool-name mouse', 'data-doc': 'Click: start a /call of this tool in the input',
            onclick: () => { insert(`/call ${tool.name} `); },
          }, tool.name),
          tool.effects.map(e => el('span', { class: `chip fill-${EFFECT_COLOR[e] || 'paper'}` }, e)),
          tool.enabled ? '' : el('span', { class: 'chip fill-paper' }, 'not offered')),
        el('div', { class: 'tool-desc mouse', 'data-doc': 'Click: expand', onclick: () => card.classList.toggle('open') }, tool.description));
      return card;
    }));
  };
  search.addEventListener('input', () => { toolQuery = search.value; draw(); });
  draw();
  const refresh = el('button', { class: 'btn btn-small', type: 'button', onclick: () => { toolCache = null; renderTools(target); } }, 'Refresh');
  target.replaceChildren(el('div', { class: 'panel' },
    el('div', { class: 'panel-section' }, el('h3', {}, `${toolCache.length} tools`, refresh), search),
    list));
}

registerPanel({
  id: 'tools', title: 'Tools', color: 'orange', order: 30,
  doc: 'The tools the agent can call; click a name to /call it yourself',
  render: renderTools, events: ['state'],
});

// ---------- UI (customize) ----------

let assetCache = null;

async function loadAssets(target) {
  try { assetCache = await api('/api/ui/assets'); } catch (err) { assetCache = { assets: [], directory: '' }; }
  if (target.isConnected && target.dataset.panel === 'ui') renderUI(target);
}

async function reset(body, target) {
  try {
    const result = await api('/api/ui/reset', { method: 'POST', body });
    window.CLAgent?.toast(result.message || 'Reset.', 'green');
  } catch (err) { window.CLAgent?.toast(err.message, 'red'); }
  assetCache = null;
  renderUI(target);
}

function renderUI(target) {
  if (!assetCache) {
    loadAssets(target);
  }
  const fontSize = getComputedStyle(document.documentElement).getPropertyValue('--font-size').trim() || '14px';
  const sizeButton = size => el('button', {
    class: `btn btn-small ${fontSize === size ? 'on' : ''}`, type: 'button',
    onclick: () => {
      document.documentElement.style.setProperty('--font-size', size);
      try { localStorage.setItem('cl-agent.font-size', size); } catch (err) { /* ignore */ }
      renderUI(target);
    },
  }, size.replace('px', ''));
  const assets = assetCache?.assets || [];
  const customized = assets.filter(a => a.layer === 'override' || a.layer === 'extension');
  target.replaceChildren(el('div', { class: 'panel' },
    el('div', { class: 'panel-section' }, el('h3', {}, 'Appearance'),
      el('div', { style: { display: 'flex', gap: '12px', flexWrap: 'wrap', alignItems: 'center' } },
        el('div', { class: 'segmented' },
          ['light', 'dark'].map(name => el('button', {
            class: `btn btn-small ${theme() === name ? 'on' : ''}`, type: 'button',
            onclick: () => { setTheme(name); renderUI(target); },
          }, name))),
        el('div', { class: 'segmented', 'data-doc': 'Text size' }, ['13px', '14px', '15px', '16px'].map(sizeButton)))),
    el('div', { class: 'panel-section' }, el('h3', {}, 'Change this UI'),
      el('div', { class: 'prose' },
        el('p', {}, 'This page is built from plain files the agent can edit. Ask it, e.g. ',
          el('em', {}, '“make the (C n) labels green”'), ', ', el('em', {}, '“add a panel listing my git branches”'),
          ' or ', el('em', {}, '“use a larger font in the listener”'),
          '. Changes are saved as overrides and patches in ', el('code', {}, assetCache?.directory || '~/.config/cl-agent/web/'),
          ' and show up here immediately.'),
        el('p', {}, 'If a change breaks the page, open ', el('a', { href: '/safe' }, 'safe mode'),
          ' (built-in files only) and reset it there, or type ', el('code', {}, '/ui reset all'), '.'))),
    el('div', { class: 'panel-section' },
      el('h3', {}, `Assets · ${customized.length} customized`,
        customized.some(a => a.layer === 'override')
          ? el('button', { class: 'btn btn-small btn-danger', type: 'button', onclick: () => reset({ all: true }, target) }, 'Reset all')
          : ''),
      assetCache ? assets.map(asset => el('div', { class: 'asset-row' },
        el('span', { class: 'asset-path', title: asset.path }, asset.path),
        el('span', { class: `chip ${{ override: 'fill-pink', extension: 'fill-violet', builtin: 'fill-paper' }[asset.layer] || 'fill-paper'}` },
          asset.patch ? `${asset.layer} patch` : asset.layer),
        el('span', { class: 'asset-actions' },
          asset.layer === 'override' ? el('button', {
            class: 'btn btn-small', type: 'button', 'data-doc': asset.builtin ? 'Go back to the built-in version' : 'Delete this file (kept in history)',
            onclick: () => reset({ path: asset.path, to: 'builtin' }, target),
          }, asset.builtin ? 'Reset' : 'Remove') : '',
          asset.history ? el('button', {
            class: 'btn btn-small', type: 'button', 'data-doc': `Restore the previous version (${asset.history} kept)`,
            onclick: () => reset({ path: asset.path, to: 'previous' }, target),
          }, 'Revert') : '')))
        : el('div', { class: 'empty' }, 'Loading…')),
    el('div', { class: 'panel-section' }, el('h3', {}, 'Keys'),
      el('div', { class: 'keys' },
        [['Enter', 'send'], ['Shift-Enter', 'new line'], ['Tab', 'complete; again to cycle'],
          ['↑ / ↓', 'history'], ['Esc', 'abort the running turn'], ['Alt-T', 'light / dark'],
          ['Alt-1…9', 'switch panel'], ['Ctrl-\\', 'hide / show panels'], ['/', 'focus the input']]
          .flatMap(([k, v]) => [el('span', { class: 'kbd' }, k), el('span', {}, v)]))),
    boot.safe ? el('div', { class: 'empty' }, 'Safe mode: overrides and patches are not loaded on this page.') : ''));
}

registerPanel({
  id: 'ui', title: 'UI', color: 'pink', order: 90,
  doc: 'Theme, text size, and what has been customized in this UI',
  badge: s => (s.ui?.overrides?.length ? '✎' : ''),
  render: renderUI, events: ['asset', 'state'],
});

on('asset', () => { assetCache = null; });
