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
| `views.js` | The main pane's tabs: the Listener, the Lisp tab, and views plugins register. |
| `menu.js` | The completion menu, shared by the input line and the Lisp editors. |
| `lisp-editor.js` | The Lisp code editor: highlighting, rainbow parens, indentation, key sequences. |
| `lisp.js` | The Lisp tab (REPL, scratch buffer, debugger, echo area) and the Inspect panel. |
| `copilot.js` | The editors' copilot: its toolbar controls and the suggestion options every editor takes. |
| `session.js` | The resume-a-session card and the model picker (title bar, Alt-M). |
| `sessions.js` | The Sessions tab (Alt-S): every stored conversation, to read, rename, resume or delete. |
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
`--title-bg --title-fg --shadow-color --shadow --stripes`; Lisp code
`--syn-comment --syn-string --syn-number --syn-keyword --syn-operator --syn-def
--syn-constant --syn-special` and the rainbow parentheses `--paren-0` …
`--paren-5`; shape `--font --font-size --line --border --gap --side-width`. Utility classes `fill-<pop>`, `chip`,
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
                        // subagents asset ui ui:<command> connection theme panels views
                        // lisp-entry lisp-output lisp-scratch lisp-clear (the Lisp tab)
                        // reset (the conversation was replaced) model (switched)
A.api(path, {method, body, params})   // fetch JSON; POSTs carry the CSRF header
A.send(text)            // send a line as if typed; A.interrupt() aborts the turn
A.insert(text)          // put text in the input box
A.toast(text, color)    // color: pink blue yellow green orange violet cyan red ink
A.setTheme('light' | 'dark' | 'toggle'); A.theme()
A.showPanel(id)         // a side panel: agents inspector activity tools ui ...
A.showView(id)          // the main pane: listener lisp ...
A.lisp.evaluate(text)   // run Lisp in the Lisp tab's REPL; A.lisp.inspect(id)
A.lisp.insert(text)     // put text in its input; A.lisp.scratch() -> the buffer
A.el(tag, attrs, ...children)   // DOM helper: attrs {class, dataset, style, onclick, html, ...}
A.esc(text); A.fmtDuration(s); A.fmtCount(n); A.fmtClock(unix); A.copyText(text)
A.storage(key, fallback); A.store(key, value)    // per-browser preferences

A.present(node, () => object, { left: 'Inspect' })   // make NODE a presentation (below)
A.inspect(object)       // show an object in the Inspect panel

A.registerPanel({ id, title, color, order, doc, badge(state), render(el, state), update(el, ev), events })
A.registerView({ id, title, color, order, doc, badge(state), mount(el), show(el), hide(el) })  // a main-pane tab
A.registerRenderer(role, (message, bodyEl, entryEl) => { ... })
A.registerMessageDecorator((entryEl, message) => { ... })
A.registerCommand(name, async argString => { ... }, doc)   // a /name handled in the browser
A.registerUICommand(name, args => { ... })                 // run by WEB-UI-COMMAND / web-ui-command
A.registerCompleter((text, cursor) => ({start, end, token, candidates: [{value, doc, kind}]}) | null)
A.registerReducer(type, ev => { ... })                     // fold a custom server event into state
```

**Presentations** (objects.js). Everything the page draws that stands for
something — a value, a message, a tool call, an agent, a file — is a
presentation of an object. The mouse boxes it, the who-line says what the
buttons do, Left runs its default command and Right opens its menu, and
Inspect shows its parts. Draw your own things the same way:

```js
A.present(A.el('span', {}, branch), () => ({
  kind: 'Branch', title: branch, type: 'GIT-BRANCH', text: branch,
  about: `the git branch ${branch}`,                  // enables "Ask the agent about it"
  parts: [['name', branch], ['ahead', '3 commits']],  // a value may be a string, a DOM
                                                      // node, or {object: anotherObject}
  commands: [{ label: 'Check it out', run: () => A.insert(`Check out the git branch ${branch}.`) },
             { label: 'Delete', danger: true, run: () => {} }],   // danger: listed last
}), { left: 'Check it out' });
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

## The Lisp tab

A SLY-style REPL on the agent's own image beside a scratch buffer shared with
the agent. Server side: `ui/web/lisp-repl.lisp` (evaluation threads, the
debugger, presentations, the scratch file `~/.config/cl-agent/repl/scratch.lisp`),
`ui/web/lisp-introspect.lisp` (completion, autodoc, describe, definitions,
macroexpansion, the inspector) and `ui/web/lisp-routes.lisp` (`/api/lisp/...`,
listed in its header). The agent reads and edits the buffer with the
`lisp-scratch` and `lisp-scratch-write` tools. Editor key bindings are plain
keymaps in `lisp.js` (`{"C-c C-c": editor => ...}`), so adding one is a small
`old`/`new` edit there.

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
