// live.js -- live sessions as vertical tabs down the page's left edge:
// several agents at once, each with its own working directory, model,
// tools and conversation (ui/web/live.lisp, docs/live-sessions.md).
//
// A tab's name runs top to bottom; a dot means it is working, a number how
// many messages arrived since you last looked.  Click to switch (Alt-↑ /
// Alt-↓); "+" (Alt-N) starts a session in a directory, with a model and a
// name; "×" stops one (the first is the agent's own and stays).  The list
// is polled, so background sessions' progress shows without their streams.
// A past session opens in a tab of its own from the Sessions view
// (openAsLive).

import { on, el, api, live, switchLive } from './core.js';

const rail = document.getElementById('live-rail');
let sessions = [];
let enabled = false;
const seen = {};          // id -> messages seen there
let formOpen = false;

async function refresh() {
  try {
    const data = await api('/api/live');
    sessions = data.sessions || [];
    enabled = !!data.enabled;
    const ids = sessions.map(s => s.id);
    // A tab remembered from before (or a session since closed): the first.
    if (live.id && !ids.includes(live.id)) { switchLive(null); return; }
    const current = live.id || data.current;
    const active = sessions.find(s => s.id === current);
    if (active) seen[active.id] = active.messages;
    for (const s of sessions) if (seen[s.id] === undefined) seen[s.id] = s.messages;
  } catch (err) { /* the server is restarting: try again on the next tick */ }
  render();
}

function activeId() { return live.id || sessions.find(s => s.primary)?.id; }

function render() {
  if (!rail) return;
  rail.hidden = !enabled && sessions.length <= 1;
  document.getElementById('desk')?.classList.toggle('with-rail', !rail.hidden);
  if (rail.hidden) return;
  const current = activeId();
  const tabs = sessions.map((s, i) => {
    const unread = s.id === current ? 0 : Math.max(0, s.messages - (seen[s.id] || 0));
    return el('div', { class: `live-tab ${s.id === current ? 'active' : ''} ${s.busy ? 'busy' : ''}`,
                       role: 'tab', 'aria-selected': String(s.id === current), tabindex: '0',
                       title: `${s.name}\n${s.directory || ''}\n${s.model || ''}${s.busy ? '\nworking…' : ''}`,
                       'data-doc': `${s.name} · ${s.directory || ''} · ${s.model || ''} (Alt-↑/↓ switch)`,
                       onclick: () => { if (s.id !== current) select(s); },
                       onkeydown: e => { if (e.key === 'Enter') select(s); } },
      el('span', { class: 'live-dot', 'aria-hidden': 'true' }),
      el('span', { class: 'live-name' }, `${i + 1} ${s.name}`),
      unread ? el('span', { class: 'live-unread', 'aria-label': `${unread} new` }, String(unread)) : '',
      s.primary ? '' : el('button', { class: 'live-close', type: 'button', 'data-doc': 'Stop this session (its log stays in Sessions)',
                                      onclick: e => { e.stopPropagation(); close(s); } }, '×'));
  });
  rail.replaceChildren(...tabs,
    el('button', { class: 'live-add', type: 'button', 'data-doc': 'Start another live session (Alt-N)',
                   onclick: () => openForm() }, '+'));
}

/** The live tab holding durable session SESSIONID, if one does. */
export function liveTabFor(sessionId) { return sessions.find(s => s.session === sessionId); }

/** Whether live sessions can be started here. */
export function liveEnabled() { return enabled; }

/** Open durable session SESSIONID in a live tab of its own (its
conversation, in the directory it worked in), or switch to the tab that
already has it. */
export async function openAsLive(sessionId) {
  const open = liveTabFor(sessionId);
  if (open) { select(open); return open; }
  const started = await api('/api/live', { method: 'POST', body: { resume: sessionId } });
  await refresh();
  switchLive(started.primary ? null : started.id);
  render();
  return started;
}

function select(s) {
  seen[s.id] = s.messages;
  switchLive(s.primary ? null : s.id);
  render();
}

async function close(s) {
  if (!confirm(`Stop the session "${s.name}"? Its conversation stays in the Sessions tab.`)) return;
  try {
    await api('/api/live/close', { method: 'POST', body: { id: s.id } });
    if (activeId() === s.id) switchLive(null);
  } catch (err) { alert(`Could not stop it: ${err.message}`); }
  refresh();
}

async function openForm() {
  if (formOpen || !enabled) return;
  formOpen = true;
  const current = sessions.find(s => s.id === activeId());
  let models = [];
  try { models = (await api('/api/models')).models || []; } catch (err) { /* this provider lists none */ }
  const directory = el('input', { class: 'field', value: current?.directory || '', spellcheck: 'false', 'aria-label': 'Working directory' });
  const model = el('select', { class: 'field', 'aria-label': 'Model' },
    el('option', { value: '' }, `same model (${current?.model || 'current'})`),
    ...models.filter(m => m !== current?.model).map(m => el('option', { value: m }, m)));
  const name = el('input', { class: 'field', placeholder: 'name (optional)', spellcheck: 'false', 'aria-label': 'Name' });
  const error = el('div', { class: 'live-form-error' });
  const form = el('form', { class: 'live-form panel', autocomplete: 'off' },
    el('h3', {}, 'New live session'),
    el('label', {}, 'Directory', directory),
    el('label', {}, 'Model', model),
    el('label', {}, 'Name', name),
    error,
    el('div', { class: 'live-form-buttons' },
      el('button', { class: 'btn btn-small', type: 'button', onclick: () => done() }, 'Cancel'),
      el('button', { class: 'btn btn-small btn-primary', type: 'submit' }, 'Start')));
  const backdrop = el('div', { class: 'live-backdrop', onclick: e => { if (e.target === backdrop) done(); } }, form);
  function done() { formOpen = false; backdrop.remove(); }
  form.addEventListener('submit', async e => {
    e.preventDefault();
    error.textContent = 'Starting…';
    try {
      const started = await api('/api/live', { method: 'POST',
        body: { directory: directory.value.trim(), model: model.value || undefined, name: name.value.trim() || undefined } });
      done();
      await refresh();
      switchLive(started.id);
      render();
    } catch (err) { error.textContent = err.message; }
  });
  form.addEventListener('keydown', e => { if (e.key === 'Escape') done(); });
  document.body.append(backdrop);
  directory.focus();
  directory.select();
}

document.addEventListener('keydown', e => {
  if (!e.altKey || e.ctrlKey || e.metaKey) return;
  if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    const ids = sessions.map(s => s.id);
    if (ids.length < 2) return;
    e.preventDefault();
    const at = Math.max(0, ids.indexOf(activeId()));
    select(sessions[(at + (e.key === 'ArrowDown' ? 1 : ids.length - 1)) % ids.length]);
  } else if (e.code === 'KeyN') {
    e.preventDefault();
    openForm();
  }
});

on('live-switch', () => render());
on('message', () => { const s = sessions.find(x => x.id === activeId()); if (s) { s.messages += 1; seen[s.id] = s.messages; } });
refresh();
setInterval(refresh, 2000);
