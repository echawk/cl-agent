// main.js -- boots the client: assembles window.CLAgent (the plugin API),
// installs the listener, composer and side panels, and owns the page-level
// chrome: title bar, who-line, mouse-documentation line, toasts, keyboard
// shortcuts, the pane splitter, and live reload when assets change.
//
// Patches (patches/*.js) are loaded after this module, so window.CLAgent is
// ready when they run; whatever they register shows up immediately.

import * as core from './core.js';
import * as render from './render.js';
import * as composer from './composer.js';
import * as panels from './panels.js';
import * as views from './views.js';
import * as session from './session.js';
import './agents.js';
import './sessions.js';
import { lispApi } from './lisp.js';

const { state, on, el, boot } = core;
const $ = id => document.getElementById(id);

// ---------- toasts and the mouse-documentation line ----------

const DEFAULT_DOC = 'Enter: send · Tab: complete · ↑↓: history · Esc: abort · Alt-L: Lisp tab · Alt-S: sessions · Alt-M: model · Alt-T: theme · Alt-1…9: panels · Ctrl-\\: panes';
let docOverride = null;
let docTimer = null;

function toast(text, color = 'ink', ms = 4200) {
  const node = el('div', { class: `toast fill-${color}`, role: 'status' }, text);
  $('toasts').append(node);
  setTimeout(() => node.remove(), ms);
  return node;
}

function mousedoc(text) {
  docOverride = text;
  $('mousedoc').textContent = text;
  clearTimeout(docTimer);
  docTimer = setTimeout(() => { docOverride = null; $('mousedoc').textContent = DEFAULT_DOC; }, 2500);
}

function installMousedoc() {
  $('mousedoc').textContent = DEFAULT_DOC;
  document.addEventListener('mouseover', e => {
    if (docOverride) return;
    const target = e.target.closest?.('[data-doc]');
    $('mousedoc').textContent = target ? target.dataset.doc : DEFAULT_DOC;
  });
}

// ---------- title bar and who-line ----------

function updateTitle() {
  const s = state.session || {};
  const stats = state.stats;
  $('title-info').textContent = [s.name, stats && `${stats.provider} · ${stats.model}`, s.cwd].filter(Boolean).join('   ');
  $('listener-info').textContent = state.connected ? (s.mode ? `mode ${s.mode}` : '') : 'disconnected';
  $('custom-flag').hidden = boot.safe || !(state.ui?.overrides?.length || state.ui?.patches?.length);
  document.title = `${state.thinking || state.planning ? '● ' : ''}cl-agent${s.name ? ` · ${s.name}` : ''}`;
}

function updateWholine() {
  const s = state.session || {};
  const stats = state.stats || {};
  const busy = state.thinking || state.planning;
  const [label, color] = !state.connected ? ['Offline', 'red']
    : state.planning ? ['Plan', 'violet']
      : state.thinking ? ['Run', 'orange'] : ['User Input', 'green'];
  const date = new Date();
  const agents = state.subagents || [];
  $('wholine').classList.toggle('running', busy && state.connected);
  $('wholine').replaceChildren(
    el('span', { 'data-doc': 'Local time' }, `${date.toLocaleDateString([], { weekday: 'short', day: '2-digit', month: 'short' })} ${date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}`),
    el('span', { 'data-doc': 'User and host' }, `${s.user || 'user'}@${s.host || 'localhost'}`),
    el('span', { 'data-doc': 'Package the agent reads Lisp in' }, 'CL-AGENT:'),
    stats.provider ? el('span', { class: 'mouse', 'data-doc': 'Provider and model · Click: choose the model (Alt-M)', onclick: () => session.openModelMenu() }, `${stats.provider} · ${stats.model}`) : '',
    stats.provider ? el('span', { 'data-doc': 'Session totals' },
      `${stats.requests} req · ${stats.tool_calls} tools · ${core.fmtCount(stats.total_tokens)} tok · ${core.fmtDuration(stats.elapsed_seconds)}`) : '',
    agents.length ? el('span', {
      class: 'wl-agents mouse', 'data-doc': 'Subagents (click: Agents panel)', onclick: () => panels.showPanel('agents'),
    }, 'agents', agents.slice(-12).map(a => el('i', { class: `state-${a.state}`, title: `${a.id} ${a.state}` }))) : '',
    state.queued?.length ? el('span', { 'data-doc': 'Messages waiting for the running turn' }, `${state.queued.length} queued`) : '',
    el('span', { class: 'wl-spacer' }),
    el('span', { class: `wl-state fill-${color}`, 'data-doc': 'Agent state' }, label));
}

// ---------- theme, panes and splitter ----------

function updateThemeButton() {
  $('theme-toggle').textContent = core.theme() === 'dark' ? '☀ Light' : '◐ Dark';
}

function togglePanes(force) {
  const hidden = $('desk').classList.toggle('side-hidden', force);
  core.store('side-hidden', hidden);
}

function installSplitter() {
  const width = core.storage('side-width', null);
  if (width) document.documentElement.style.setProperty('--side-width', `${width}px`);
  const splitter = $('splitter');
  splitter.addEventListener('pointerdown', e => {
    e.preventDefault();
    splitter.classList.add('dragging');
    splitter.setPointerCapture(e.pointerId);
    const move = ev => {
      const next = Math.max(280, Math.min(window.innerWidth - 360, window.innerWidth - ev.clientX - 14));
      document.documentElement.style.setProperty('--side-width', `${next}px`);
      core.store('side-width', next);
    };
    const up = () => {
      splitter.classList.remove('dragging');
      splitter.removeEventListener('pointermove', move);
      splitter.removeEventListener('pointerup', up);
    };
    splitter.addEventListener('pointermove', move);
    splitter.addEventListener('pointerup', up);
  });
}

// ---------- keyboard ----------

function installKeys() {
  document.addEventListener('keydown', e => {
    if (e.altKey && (e.key === 't' || e.key === 'T' || e.code === 'KeyT')) { e.preventDefault(); core.setTheme('toggle'); return; }
    if (e.altKey && !e.ctrlKey && e.code === 'KeyM') { e.preventDefault(); session.openModelMenu(); return; }
    if (e.altKey && !e.ctrlKey && e.code === 'KeyS') {
      e.preventDefault();
      views.showView(views.activeView() === 'sessions' ? 'listener' : 'sessions');
      return;
    }
    if (e.altKey && !e.ctrlKey && e.code === 'KeyL') {
      e.preventDefault();
      views.showView(views.activeView() === 'lisp' ? 'listener' : 'lisp');
      return;
    }
    if (e.altKey && /^Digit[1-9]$/.test(e.code)) {
      const id = panels.panelIds()[Number(e.code.slice(5)) - 1];
      if (id) { e.preventDefault(); panels.showPanel(id); }
      return;
    }
    if (e.ctrlKey && e.key === '\\') { e.preventDefault(); togglePanes(); return; }
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
    if (!typing && e.key === '/' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      if ($('input').value) $('input').focus(); else composer.insert('/');
    }
  });
}

// ---------- live reload ----------

let reloadTimer = null;

function onAsset(ev) {
  if (boot.safe) return;
  const linked = new Set([...document.querySelectorAll('link[data-core],link[data-patch]')]
    .map(link => link.dataset.core || link.dataset.patch));
  const needsReload = ev.reload || ev.paths.some(path => path.endsWith('.css') && path.startsWith('patches/') && !linked.has(path))
    || ev.paths.includes('index.html');
  if (needsReload) {
    clearTimeout(reloadTimer);
    toast('UI updated: reloading…', 'yellow', 1500);
    reloadTimer = setTimeout(() => location.reload(), 350);
    return;
  }
  for (const link of document.querySelectorAll('link[data-core],link[data-patch]')) {
    const path = link.dataset.core || link.dataset.patch;
    if (ev.paths.includes(path)) {
      const url = new URL(link.href);
      url.searchParams.set('v', Date.now());
      link.href = url.toString();
    }
  }
  toast(`Restyled: ${ev.paths.join(', ')}`, 'green', 2200);
  core.api('/api/ui/assets').then(data => {
    state.ui.overrides = data.assets.filter(a => a.layer === 'override').map(a => a.path);
    updateTitle();
  }).catch(() => {});
}

// ---------- built-in commands ----------

function installCommands() {
  core.registerUICommand('toast', args => toast(String(args.text ?? ''), args.color || 'ink', args.ms || 4200));
  core.registerUICommand('theme', args => core.setTheme(args.theme || 'toggle'));
  core.registerUICommand('panel', args => panels.showPanel(args.id));
  core.registerUICommand('view', args => views.showView(args.id));
  core.registerUICommand('insert', args => composer.insert(String(args.text ?? '')));
  core.registerUICommand('reload', () => location.reload());

  core.registerCommand('clear', () => render.clearListener(), 'Clear the listener (the conversation itself is kept)');
  core.registerCommand('panel', arg => {
    const id = arg.trim();
    if (!panels.panelIds().includes(id)) throw new Error(`Panels: ${panels.panelIds().join(', ')}`);
    panels.showPanel(id);
  }, 'Open a side panel: /panel agents|activity|tools|ui');
  core.registerCompleter((text, cursor) => {
    const match = text.slice(0, cursor).match(/^\/panel (\S*)$/);
    if (!match) return null;
    return {
      start: 6, end: cursor, token: match[1], source: 'command:panel',
      candidates: panels.panelIds().filter(id => id.startsWith(match[1])).map(id => ({ value: id, kind: 'panel', doc: core.panels.get(id).doc })),
    };
  });
}

// ---------- the public API ----------

const CLAgent = {
  version: '2.0',
  ...core,
  toast,
  mousedoc,
  insert: composer.insert,
  complete: composer.complete,
  showPanel: panels.showPanel,
  showView: views.showView,
  lisp: lispApi,
  sanitize: render.sanitize,
  scrollToLatest: render.scrollToLatest,
};
window.CLAgent = CLAgent;

// ---------- boot ----------

installCommands();
render.install();
composer.install();
panels.install();
views.install();
session.install();
installMousedoc();
installKeys();
installSplitter();
if (core.storage('side-hidden', false)) togglePanes(true);

$('theme-toggle').addEventListener('click', () => core.setTheme('toggle'));
$('pane-toggle').addEventListener('click', () => togglePanes());
$('custom-flag').addEventListener('click', () => panels.showPanel('ui'));
$('safe-banner').hidden = !boot.safe;
$('reset-all').addEventListener('click', async () => {
  try {
    const result = await core.api('/api/ui/reset', { method: 'POST', body: { all: true } });
    toast(`Reset ${result.reset.length} override(s). Leave safe mode to see the built-in UI.`, 'green', 6000);
  } catch (err) { toast(err.message, 'red'); }
});

on('theme', updateThemeButton);
on('asset', onAsset);
// The conversation was replaced (/session resume, restore, rewind): start over.
on('reset', () => core.loadState());
on('connection', connected => {
  updateTitle();
  updateWholine();
  if (!connected) mousedoc('Lost the connection to cl-agent — retrying…');
});
for (const type of ['state', 'status', 'subagents']) on(type, () => { updateTitle(); updateWholine(); });
setInterval(updateWholine, 1000);

updateThemeButton();
updateTitle();
updateWholine();
core.loadState();
