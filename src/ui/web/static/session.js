// session.js -- picking up where you left off, and choosing the model
// (server side: ui/web/session-routes.lisp).
//
//   Resume card   whenever the Listener holds no conversation -- a fresh
//                 start, or cl-agent restarted under an open page -- and an
//                 earlier session had one, a card offers to resume it (or
//                 another recent one).  Resuming runs /session resume on the
//                 agent's own thread; the conversation then streams back in.
//   Model         the title bar's model button (Alt-M) opens a menu of the
//                 provider's models; started with --ui web and no :model
//                 configured, a card asks before the first message.
//                 "Make it my default" saves :model in config.lisp.

import { state, on, el, api, storage, store } from './core.js';

const toast = (text, color) => window.CLAgent?.toast(text, color);
const $ = id => document.getElementById(id);

// ---------- small pieces ----------

function ago(unix) {
  if (!unix) return '';
  const s = Math.max(0, Date.now() / 1000 - unix);
  if (s < 90) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  if (s < 86400 * 14) return `${Math.round(s / 86400)} days ago`;
  return new Date(unix * 1000).toLocaleDateString();
}

function card(id, title, color, ...body) {
  return el('section', { class: 'offer-card', 'data-card': id, style: { '--card-color': `var(--${color})`, '--card-on': `var(--on-${color})` } },
    el('div', { class: 'offer-title' }, title), ...body);
}

function setCard(id, node) {
  const offer = $('offer');
  offer.querySelector(`[data-card="${id}"]`)?.remove();
  if (node) {
    // The model question comes first: it applies to whatever happens next.
    if (id === 'model') offer.prepend(node); else offer.append(node);
  }
  offer.hidden = !offer.children.length;
}

const hasConversation = () => state.messages.some(m => m.role === 'user');

// ---------- resuming a session ----------

let restarted = false;            // this page saw a different server before
let offeredFor = null;            // the instance the card was last built for

function noteInstance() {
  if (!state.instance) return;
  const previous = storage('instance', null);
  if (previous && previous !== state.instance) restarted = true;
  store('instance', state.instance);
}

function dismissed() {
  try { return sessionStorage.getItem('cl-agent.resume-dismissed') === state.instance; } catch (err) { return false; }
}

function dismiss() {
  try { sessionStorage.setItem('cl-agent.resume-dismissed', state.instance); } catch (err) { /* ignore */ }
  setCard('resume', null);
}

async function resume(session, button) {
  if (button) { button.disabled = true; button.textContent = 'Resuming…'; }
  try {
    await api('/api/sessions/resume', { method: 'POST', body: { id: session.id } });
    setCard('resume', null);
    toast(`Resuming "${session.title || session.id}"…`, 'green');
  } catch (err) {
    if (button) { button.disabled = false; button.textContent = 'Resume'; }
    toast(err.message, 'red');
  }
}

function sessionRow(session, primary = false) {
  const button = el('button', {
    class: `btn btn-small ${primary ? 'btn-primary' : ''}`, type: 'button',
    'data-doc': `Resume ${session.id}: its conversation comes back into the Listener`,
    onclick: () => resume(session, button),
  }, 'Resume');
  return el('div', { class: `resume-row ${primary ? 'primary' : ''}` },
    el('div', { class: 'resume-text' },
      el('div', { class: 'resume-name' }, session.name || session.title || session.id),
      el('div', { class: 'resume-meta' },
        `${session.user_messages} message${session.user_messages === 1 ? '' : 's'} from you · ${ago(session.last_active)}`,
        session.last && session.last !== session.title ? el('span', { class: 'faint' }, ` · last: ${session.last}`) : '')),
    button);
}

async function offerResume() {
  if (!state.connected || !state.instance) return;
  if (hasConversation() || dismissed()) { setCard('resume', null); return; }
  if (offeredFor === state.instance) return;
  offeredFor = state.instance;
  let data;
  try { data = await api('/api/sessions/recent'); } catch (err) { return; }
  if (hasConversation() || !data.sessions.length) return;
  const [latest, ...others] = data.sessions;
  setCard('resume', card('resume', restarted ? 'cl-agent restarted · resume?' : 'Resume a session?', 'green',
    el('p', { class: 'offer-lead' }, restarted
      ? 'The agent was restarted, so this conversation starts empty. Pick up where you left off:'
      : 'Pick up where you left off, or just start typing for a fresh conversation.'),
    sessionRow(latest, true),
    others.length ? el('details', { class: 'resume-more' },
      el('summary', {}, `${others.length} more recent session${others.length === 1 ? '' : 's'}`),
      others.map(s => sessionRow(s))) : '',
    el('div', { class: 'offer-actions' },
      el('button', { class: 'btn btn-small', type: 'button', onclick: dismiss, 'data-doc': 'Keep this conversation empty' }, 'Start fresh'))));
}

// ---------- the model ----------

let models = null;               // the last /api/models answer

async function loadModels() {
  models = await api('/api/models');
  updateButton();
  return models;
}

async function choose(model, remember) {
  try {
    const result = await api('/api/model', { method: 'POST', body: { model, remember } });
    closeMenu();
    setCard('model', null);
    if (result.error) toast(result.error, 'orange');
    else toast(result.saved ? `Model: ${model} (saved as your default)` : `Model: ${model}`, 'green');
  } catch (err) { toast(err.message, 'red'); }
}

function modelList(data, { remember }) {
  const filter = el('input', {
    class: 'field model-filter', type: 'search', placeholder: `Filter ${data.models.length} models…`, spellcheck: 'false',
  });
  const list = el('div', { class: 'model-list', role: 'listbox' });
  const render = () => {
    const q = filter.value.trim().toLowerCase();
    const shown = data.models.filter(m => m.toLowerCase().includes(q));
    list.replaceChildren(...shown.map(m => el('button', {
      class: `model-option ${m === data.current ? 'current' : ''}`, type: 'button', role: 'option',
      'data-doc': m === data.current ? 'The model in use' : `Use ${m} from now on`,
      onclick: () => choose(m, remember.checked),
    }, el('span', { class: 'model-mark' }, m === data.current ? '●' : ''), m,
       m === data.default ? el('span', { class: 'chip fill-paper' }, 'default') : '')));
    if (!shown.length) list.append(el('div', { class: 'empty' }, 'No model matches.'));
  };
  filter.addEventListener('input', render);
  filter.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); list.querySelector('.model-option')?.click(); }
    if (e.key === 'Escape') closeMenu();
  });
  render();
  return { filter, list };
}

function rememberBox(checked) {
  const box = el('input', { type: 'checkbox', checked });
  return { box, label: el('label', { class: 'model-remember', 'data-doc': 'Writes :model into ~/.config/cl-agent/config.lisp (comments are kept)' }, box, ' Make it my default (config.lisp)') };
}

async function askForModel() {
  if (!state.ui?.model_pending) { setCard('model', null); return; }
  let data;
  try { data = await loadModels(); } catch (err) { return; }
  if (!data.pending) { setCard('model', null); return; }
  const remember = rememberBox(true);
  const body = data.models.length
    ? modelList(data, { remember: remember.box })
    : { filter: '', list: el('p', { class: 'offer-lead' }, `Could not list ${data.provider}'s models${data.error ? `: ${data.error}` : ''}.`) };
  setCard('model', card('model', 'Choose a model', 'violet',
    el('p', { class: 'offer-lead' }, `No model is configured for ${data.provider}. Pick the one to talk to (currently ${data.current}):`),
    data.models.length > 8 ? body.filter : '', body.list,
    el('div', { class: 'offer-actions' }, remember.label,
      el('button', { class: 'btn btn-small', type: 'button', onclick: () => choose(data.current, false), 'data-doc': 'Use the provider\'s default and stop asking' }, `Keep ${data.current}`))));
}

// The title bar's menu.
let menu = null;

function closeMenu() {
  menu?.remove();
  menu = null;
  document.removeEventListener('mousedown', outside, true);
}

function outside(e) {
  if (menu && !menu.contains(e.target) && e.target !== $('model-button')) closeMenu();
}

export async function openModelMenu() {
  if (menu) { closeMenu(); return; }
  const anchor = $('model-button');
  menu = el('div', { class: 'model-menu', role: 'dialog', 'aria-label': 'Choose a model' },
    el('div', { class: 'completions-title' }, el('span', {}, 'Model'), el('span', {}, 'Esc closes')),
    el('div', { class: 'model-menu-body' }, el('div', { class: 'empty' }, 'Asking the provider for its models…')));
  document.body.append(menu);
  const rect = anchor.getBoundingClientRect();
  menu.style.top = `${rect.bottom + 6}px`;
  menu.style.right = `${Math.max(8, window.innerWidth - rect.right)}px`;
  document.addEventListener('mousedown', outside, true);
  let data;
  try { data = await loadModels(); } catch (err) {
    menu?.querySelector('.model-menu-body').replaceChildren(el('div', { class: 'empty' }, err.message));
    return;
  }
  if (!menu) return;
  const remember = rememberBox(false);
  const body = menu.querySelector('.model-menu-body');
  if (!data.models.length) {
    body.replaceChildren(el('div', { class: 'empty' }, `${data.provider} did not list any models${data.error ? `: ${data.error}` : ''}. Using ${data.current}.`));
    return;
  }
  const { filter, list } = modelList(data, { remember: remember.box });
  body.replaceChildren(el('div', { class: 'model-menu-head' }, `${data.provider} · using `, el('b', {}, data.current)),
    filter, list, remember.label);
  filter.focus();
}

function updateButton() {
  const button = $('model-button');
  if (!button) return;
  const model = models?.current || state.stats?.model || state.session?.model;
  button.textContent = `◆ ${model || 'Model'}`;
  button.classList.toggle('pending', !!state.ui?.model_pending);
}

// ---------- wiring ----------

export function install() {
  $('model-button').addEventListener('click', openModelMenu);
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && menu) closeMenu(); });
  on('state', () => { noteInstance(); offerResume(); askForModel(); updateButton(); });
  on('connection', connected => { if (connected) offerResume(); });
  on('message', ev => { if (ev.message.role === 'user') setCard('resume', null); });
  on('status', updateButton);
  on('model', ev => {
    if (state.ui) state.ui.model_pending = ev.pending;
    if (models) models.current = ev.model;
    setCard('model', null);
    updateButton();
  });
  updateButton();
}
