// lem-view.js -- Lem's own view of itself, in an iframe: Lem's web frontend
// showing the hosted Lem (server side: lem/display.lisp).  The Code tab's
// editor and the Lisp tab's scratch buffer each have one; there is one Lem,
// so both show what its window shows, and each tab puts its own buffer
// there when it is shown.
//
// Lem looks like the page: its colours are a Lem theme made from the
// page's theme tokens, sent again whenever the theme changes; its font and
// size are the page's; its chrome takes a few colours as --cl-* variables.
// A view survives what used to leave it blank: it is measured again when
// the page's layout changes, rebuilt when the server restarted (a new
// display port), retried while Lem starts, and says "Starting Lem..."
// until Lem's client has logged in.

import { on, el, api, state } from './core.js';

const TOKENS = ['paper', 'paper-2', 'paper-3', 'ink', 'ink-2', 'ink-3', 'rule', 'rule-soft', 'select', 'code-inline',
  'red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'violet', 'pink', 'on-yellow', 'on-pink', 'title-bg', 'title-fg',
  'shadow-color', 'syn-comment', 'syn-string', 'syn-number', 'syn-keyword', 'syn-operator', 'syn-def', 'syn-constant', 'syn-special'];

const views = new Set();

function pageColors() {
  const probe = el('span', { hidden: true });
  document.body.append(probe);
  const colors = {};
  for (const name of TOKENS) {
    probe.style.color = '';
    probe.style.color = `var(--${name})`;
    const rgb = getComputedStyle(probe).color.match(/[\d.]+/g);
    if (rgb && rgb.length >= 3) colors[name] = '#' + rgb.slice(0, 3).map(v => Math.round(+v).toString(16).padStart(2, '0')).join('');
  }
  probe.remove();
  return colors;
}

const chromeVars = colors => ({ paper: colors.paper, rule: colors.rule, 'rule-soft': colors['rule-soft'], shadow: colors['shadow-color'] });

/** Give Lem the page's colours (the theme, and every view's chrome). */
function pushTheme(onError) {
  const colors = pageColors();
  for (const v of views) v.frame?.contentWindow?.postMessage({ type: 'cl-agent-style', vars: chromeVars(colors) }, '*');
  // Light or dark by the theme's color-scheme: "mono" and patches' themes too.
  const mode = /dark/.test(getComputedStyle(document.documentElement).colorScheme) ? 'dark' : 'light';
  return api('/api/lem/theme', { method: 'POST', body: { mode, colors } }).catch(err => onError?.(`Lem theme: ${err.message}`));
}

async function frameURL() {
  const style = getComputedStyle(document.documentElement);
  const font = style.getPropertyValue('--font').trim() || 'monospace';
  const size = Math.round(parseFloat(style.getPropertyValue('--font-size')) || 14);
  const { url } = await api('/api/lem/display', { params: { font, size } });
  const chrome = Object.entries(chromeVars(pageColors())).filter(([, v]) => v);
  return url + '&' + new URLSearchParams(chrome);
}

/** A Lem view in HOST (an element): {ensure, remeasure, focus, drop, frame}.
WANTED says whether it should exist now (its tab in Lem mode); MESSAGE
reports trouble. */
export function createLemView(host, { wanted = () => true, message = () => {} } = {}) {
  const v = { frame: null, instance: null, pending: null, retry: 0, startTimer: 0, resizeTimer: 0, observer: null };

  function drop() {
    v.frame?.remove();
    v.frame = null;
    v.instance = null;
  }

  // Lem's client measures itself on its window's resize event, which an
  // iframe does not always get when only the page's layout changes: tell
  // it, once the size settles.  A hidden frame (0x0) is not measured.
  function remeasure() {
    clearTimeout(v.resizeTimer);
    v.resizeTimer = setTimeout(() => {
      if (!v.frame || !v.frame.offsetWidth || !v.frame.offsetHeight) return;
      v.frame.contentWindow?.postMessage({ type: 'cl-agent-resize' }, '*');
    }, 120);
  }

  function started() {
    clearTimeout(v.startTimer);
    host.classList.remove('starting');
    remeasure();
  }

  function ensure() {
    // A restarted server has a new display (another port): this one is dead.
    if (v.frame && v.instance && state.instance && v.instance !== state.instance) drop();
    if (v.frame) return Promise.resolve(v.frame);
    if (!v.pending) {
      v.pending = (async () => {
        try {
          await pushTheme(message);
          const frame = el('iframe', { class: 'code-lem-frame', src: await frameURL(), title: 'Lem', allow: 'clipboard-read; clipboard-write' });
          v.frame = frame;
          v.instance = state.instance;
          // Lem's client loads its code and font before it draws.
          host.replaceChildren(frame, el('div', { class: 'code-lem-starting' }, 'Starting Lem…'));
          host.classList.add('starting');
          clearTimeout(v.startTimer);
          v.startTimer = setTimeout(started, 30000);
          v.observer?.disconnect();
          if (typeof ResizeObserver !== 'undefined') { v.observer = new ResizeObserver(remeasure); v.observer.observe(host); }
        } catch (err) {
          message(`Lem view unavailable: ${err.message}`);
          // Lem may still be starting: try again while the view is wanted.
          clearTimeout(v.retry);
          v.retry = setTimeout(() => { if (wanted() && !v.frame) ensure(); }, 3000);
        }
        v.pending = null;
        return v.frame;
      })();
    }
    return v.pending;
  }

  const focus = () => setTimeout(() => { v.frame?.focus(); v.frame?.contentWindow?.focus(); }, 0);

  v.drop = drop;
  v.ensure = ensure;
  v.wanted = wanted;
  v.started = started;
  views.add(v);
  return { ensure, remeasure, focus, drop, get frame() { return v.frame; } };
}

on('state', () => {
  for (const v of views) {
    if (!v.frame) continue;
    if (!v.instance) { v.instance = state.instance; continue; }   // made before the first state
    if (state.instance && v.instance !== state.instance) { v.drop(); if (v.wanted()) v.ensure(); }
  }
});
on('theme', () => { if ([...views].some(v => v.frame)) pushTheme(); });
// A new size means new cells: the client measures its font once.
on('font-size', async () => {
  for (const v of views) if (v.frame) v.frame.src = await frameURL();
});
// Lem's client has logged in: it draws now.
on('lem-display', () => { for (const v of views) if (v.frame) v.started(); });
