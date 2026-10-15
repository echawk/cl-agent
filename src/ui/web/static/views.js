// views.js -- the main pane's tabs: the Listener (the conversation with the
// agent) and every registered view, e.g. the Lisp tab (lisp.js) and the
// Sessions tab (sessions.js).  A view is
// {id, title, color, order, doc, badge(state), mount(el), show(el)?, hide(el)?}
// (CLAgent.registerView); mount runs once, the first time it is shown, with
// the view's own container.  Alt-L toggles between the Listener and Lisp,
// Alt-S between the Listener and Sessions.

import { state, on, el, views, registerView, storage, store, frameThrottle } from './core.js';

const $ = id => document.getElementById(id);
let active = storage('view', 'listener');
const mounted = new Set(['listener']);

function ordered() {
  return [...views.values()].sort((a, b) => (a.order - b.order) || a.title.localeCompare(b.title));
}

function container(view) {
  let node = document.querySelector(`.view[data-view="${view.id}"]`);
  if (!node) {
    node = el('div', { class: `view ${view.id}-view`, 'data-view': view.id, hidden: true });
    $('main-pane').append(node);
  }
  return node;
}

function renderTabs() {
  $('main-tabs').replaceChildren(...ordered().map(view => {
    const badge = view.badge ? view.badge(state) : '';
    return el('button', {
      class: `tab ${view.id === active ? 'active' : ''}`,
      type: 'button', role: 'tab',
      style: { '--tab-color': `var(--${view.color})`, '--tab-on': `var(--on-${view.color})` },
      'data-doc': view.doc || view.title,
      onclick: () => showView(view.id),
    }, view.title, badge ? el('span', { class: 'badge' }, badge) : '');
  }));
}

export function showView(id) {
  if (!views.has(id)) return;
  const previous = views.get(active);
  active = id;
  // The page knows which view is in front (app.css: the Lisp tab has its own prompt).
  document.getElementById('frame')?.setAttribute('data-view', id);
  store('view', id);
  for (const view of views.values()) {
    const node = container(view);
    const shown = view.id === id;
    if (shown && !mounted.has(view.id)) {
      mounted.add(view.id);
      try { view.mount?.(node); } catch (err) { console.error(`[cl-agent] view ${view.id} failed`, err); }
    }
    if (node.hidden === shown) {
      node.hidden = !shown;
      if (!shown && view === previous) view.hide?.(node);
    }
  }
  views.get(id).show?.(container(views.get(id)));
  renderTabs();
}

export function activeView() { return active; }
export function viewIds() { return ordered().map(v => v.id); }

export function install() {
  registerView({
    id: 'listener', title: 'Listener', color: 'blue', order: 0,
    doc: 'The conversation with the agent',
    show: () => $('input').focus(),
  });
  const refresh = frameThrottle(renderTabs);
  on('views', () => { renderTabs(); if (views.has(active) && !mounted.has(active)) showView(active); });
  on('change', refresh);
  on('state', refresh);
  if (!views.has(active)) active = 'listener';
  showView(active);
}
