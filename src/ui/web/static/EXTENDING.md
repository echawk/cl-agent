# Customizing the cl-agent web UI

The browser UI (`--ui web`) is a handful of plain files that you, or the agent
on your behalf, can change while it runs. Pages update immediately: CSS
changes restyle in place, anything else reloads the page.

## Files

| Asset | What it is |
|---|---|
| `index.html` | The frame. Keep the `{{ASSETS}}`, `{{BOOT}}`, `{{PATCH_STYLES}}`, `{{PATCH_SCRIPTS}}` placeholders. |
| `theme.css` | **Every color, font and size**, as CSS custom properties, for light and `[data-theme="dark"]`. |
| `app.css` | Layout and components. It uses only theme tokens. |
| `core.js` | State store, event bus, server transport, plugin registries, helpers. |
| `render.js` | The Listener: `(C n)` inputs, `(D n)` replies, tool-call lines, streaming. |
| `composer.js` | The input line: send, history, tab-completion menu, abort. |
| `panels.js` | The side-pane tab host plus the Activity, Tools and UI panels. |
| `agents.js` | The Agents panel: the subagent constellation, tree/timeline, details. |
| `main.js` | Boot, `window.CLAgent`, who-line, mouse-doc line, keys, toasts, live reload. |
| `patches/*.css`, `patches/*.js` | **Your additions.** Loaded after the core files, in name order. |

Every asset is resolved through three layers, first match wins:

1. **override**: `~/.config/cl-agent/web/PATH`, written by `web-ui-write-asset`.
2. **extension**: registered from Lisp with `define-web-patch` / `register-web-asset`.
3. **builtin**: `src/ui/web/static/PATH`, compiled into the image.

`/safe` serves built-ins only, so a broken override can always be undone
there with **Reset every override**. `/ui reset PATH|all` and `/ui revert PATH`
do the same from the input line, and `web-ui-reset-asset` does it for the agent.
Each overwritten version is kept in `~/.config/cl-agent/web/.history/`.

## Choosing the smallest change

1. **Restyle** → write `patches/NAME.css` that overrides tokens or rules:

   ```css
   :root { --user: var(--green); --font-size: 15px; }
   [data-theme="dark"] { --paper: #101418; }
   .entry.assistant .label { text-decoration: underline; }
   ```

2. **Add behavior or a panel** → write `patches/NAME.js` (an ES module) using
   `window.CLAgent`.
3. **Need data from Lisp** → add a route in an extension file with
   `define-web-route` (via `write-extension`) and fetch it from your patch.
4. **Edit a core file** only when 1–3 cannot do it. Use `web-ui-write-asset`
   with `old`/`new` to change one snippet instead of rewriting the file.

## Theme tokens (theme.css)

Surfaces `--paper --paper-2 --paper-3 --desk --desk-dot`; ink `--ink --ink-2
--ink-3 --rule --rule-soft`; pops `--pink --blue --yellow --green --orange
--violet --cyan --red`, each with a readable text color `--on-<pop>`; roles
`--user --assistant --system --tool --error --select --code-inline`; chrome
`--title-bg --title-fg --shadow-color --shadow`; shape `--font --font-size
--line --border --gap --side-width`. Utility classes `fill-<pop>`, `chip`,
`btn`, `btn-small`, `btn-primary`, `btn-danger`, `panel`, `panel-section`,
`empty`, `field`, `mouse` (hover box), `muted`, `faint` are free to reuse.
Put `data-doc="..."` on any element to show help in the mouse-doc line
when the pointer is over it.

## The CLAgent API (window.CLAgent)

```js
const A = window.CLAgent;

A.state                 // live: messages, pending, thinking, planning, queued, turn,
                        // stats, activity, subagents, session, ui, connected, seq
A.on(type, fn)          // returns an unsubscribe function; fn(detail, state)
                        // types: state change message delta pending activity status
                        // subagents asset ui ui:<command> connection theme panels
A.api(path, {method, body, params})   // fetch JSON; POSTs carry the CSRF header
A.send(text)            // send a line as if typed; A.interrupt() aborts the turn
A.insert(text)          // put text in the input box
A.toast(text, color)    // color: pink blue yellow green orange violet cyan red ink
A.setTheme('light' | 'dark' | 'toggle'); A.theme()
A.showPanel(id)
A.el(tag, attrs, ...children)   // DOM helper: attrs {class, dataset, style, onclick, html, ...}
A.esc(text); A.fmtDuration(s); A.fmtCount(n); A.fmtClock(unix); A.copyText(text)
A.storage(key, fallback); A.store(key, value)    // per-browser preferences

A.registerPanel({ id, title, color, order, doc, badge(state), render(el, state), update(el, ev), events })
A.registerRenderer(role, (message, bodyEl, entryEl) => { ... })
A.registerMessageDecorator((entryEl, message) => { ... })
A.registerCommand(name, async argString => { ... }, doc)   // a /name handled in the browser
A.registerUICommand(name, args => { ... })                 // run by WEB-UI-COMMAND / web-ui-command
A.registerCompleter((text, cursor) => ({start, end, token, candidates: [{value, doc, kind}]}) | null)
A.registerReducer(type, ev => { ... })                     // fold a custom server event into state
```

A message is `{id, role, text, html, turn, time, inline}`, with role `user`,
`assistant`, `system`, `error`, `tool` or `compaction`. An activity entry is
`{id, kind, label, text, turn, time, tool, ref}`, with kind `tool-call`,
`tool-output` (whose `ref` is its call's id), `system`, `error`, `narration`,
`planning`, `subagent` or `event`. A subagent is `{id, state, role, profile,
model, description, activity, note, depth, tools, requests, tool_calls,
tokens, created, started, finished}`, with times in Unix seconds.

### Example: a panel (patches/clock-panel.js)

```js
const A = window.CLAgent;
A.registerPanel({
  id: 'clock', title: 'Clock', color: 'cyan', order: 60,
  doc: 'What time it is',
  render(el) {
    el.replaceChildren(A.el('div', { class: 'panel' },
      A.el('div', { class: 'panel-section' }, A.el('h3', {}, 'Now'), new Date().toLocaleString())));
  },
  events: ['status'],
});
```

### Example: decorate replies (patches/word-count.js)

```js
window.CLAgent.registerMessageDecorator((entry, message) => {
  if (message.role !== 'assistant') return;
  entry.querySelector('.body').append(
    window.CLAgent.el('div', { class: 'faint' }, `${message.text.split(/\s+/).length} words`));
});
```

## Lisp side (write-extension files)

```lisp
(in-package :cl-agent)

;; A JSON endpoint; the body's value is the response (a hash table or list
;; becomes JSON).  *WEB-FRONTEND* is the frontend serving the request.
(define-web-route git-branches (:path "/api/ext/git-branches")
  (jobj "branches" (jarray (uiop:run-program '("git" "branch" "--format=%(refname:short)")
                                             :output :lines :ignore-error-status t))))

;; A patch carried by the extension itself, instead of a file.
(define-web-patch git-panel
  :css ".branch { color: var(--green); }"
  :js "const A = window.CLAgent; A.registerPanel({ id: 'git', title: 'Git', color: 'green',
         async render(el) { const { branches } = await A.api('/api/ext/git-branches');
           el.replaceChildren(A.el('div', { class: 'panel' },
             branches.map(b => A.el('div', { class: 'branch' }, b)))); } });")

;; Push to open pages now.
(web-ui-command "toast" (jobj "text" "Deployed!" "color" "green"))
(web-ui-broadcast "build-status" (jobj "ok" t))   ; CLAgent.on('build-status', ...)

;; Tab completion for a slash command's arguments.
(define-command-completer "deploy" (context)
  (when (= (getf context :arg-index) 0)
    (list (make-completion "staging" :doc "the test cluster")
          (make-completion "production" :doc "careful"))))
```

Hook points: `:web-ui-page` (chain; `(:html STRING :safe BOOL)` before the
page is served), `:web-ui-state` (chain; the `/api/state` hash table),
`:web-ui-asset-changed` (notify; the path). The routes built in are listed
at the top of `src/ui/web/routes.lisp`; mutating requests need the
`X-CL-Agent` header, which `CLAgent.api` adds for you.
