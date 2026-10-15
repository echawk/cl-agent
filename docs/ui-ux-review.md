# cl-agent web UI: UI/UX review and design record

This is the durable record for the UI/UX pass asked for in the two design
briefs (the review prompt and its working-mode addendum, kept outside the
repository). It holds the audit first, then the plan, then what was decided
while implementing it. Recommendations that turn out to rest on a wrong
reading of the application are corrected here, not forced into the code.

The one-line brief: *what might a Lisp Machine environment have evolved into
if agentic LLMs had become another native computational primitive?* The
owner's own summary of the direction: **one listener to rule them all**. Lisp
forms, questions for the agent, commands and editing all go through the
same interface, in the manner of a Genera listener. The application stays a
web UI and keeps its other faces (the MCP server, ACP, the CLI and TUI).

Evidence for this audit:
- reading `src/ui/web/static/` (index.html, theme.css, app.css, core.js,
  composer.js, render.js, main.js, lisp.js, code.js, agents.js, panels.js,
  lem-view.js, live.js) and the routes behind them;
- running a server against a scratch project and screenshotting every
  view and panel in light and dark at 1440×900 and at 760 px wide;
- the owner's critique board (a mock-up with a Clippy "Ask" button, a dark
  variant and a monochrome "Lisp Machine" variant) and the Clippy pixel
  icon.

---

## 1. Existing design philosophy

- **A Lisp-machine desk, not a web app.** Square panes with 2 px ruled
  borders and inverse title bars sit on a dithered Interlisp-D desktop.
  Along the bottom run a who-line and a Genera-style mouse-documentation
  line.
- **Early-Apple colour, used for meaning.** The six-band rainbow appears as
  the title-bar racing stripes and the running bar. Colours name roles:
  pink is you, blue the agent, violet tools and commands, orange the Code
  tab, green "ready".
- **Macsyma-style transcript.** Inputs are `(C n)` and replies `(D n)`.
  Tool calls fold into one `;; n tool calls` line, and their detail lives in
  the Activity panel.
- **SLY-grade Lisp.** Presentations, the inspector, an SLDB-style debugger
  with real restarts, arglists in an echo area, and completion through
  slynk itself.
- **The UI is editable by the agent.** It is built from layered assets,
  with override files, patches and safe mode.

## 2. What is already excellent and should not change (PRESERVE)

- The overall geometry: hard rectangles, 2 px rules, hard offset shadows
  (`4px 4px 0`), no radii. The critique board agrees.
- The who-line and the mouse-documentation line. `data-doc` on almost
  every control is a real Genera idiom, and it is used consistently.
- `(C n)` / `(D n)` labels and the collapsed tool-call line.
- The Lisp tab's debugger box and its restarts, number keys included.
- Presentations: any printed value can be clicked to inspect it.
- The λ glyph, the racing stripes, the dithered desk. The `herald`
  banner on an empty listener.
- Information density in the Activity and Tools panels.

## 3. Mental model of the interface

| Area | What it is | Persistent? |
|---|---|---|
| Title bar | name, session, provider · model, cwd; model, panes, theme | yes |
| Live rail | live sessions as vertical tabs (only with more than one) | yes |
| Main pane | **views**: Listener, Lisp, Code, Sessions (plugins add more) | one at a time |
| Side pane | **panels**: Agents, Inspect, Activity, Tools, UI | one at a time |
| Composer | the input line: `(C n)` prompt, Tab completion, history | yes |
| Who-line | time, user@host, package, model, totals, subagents, state | yes |
| Mouse-doc | what the thing under the mouse does | yes |

The vocabulary in use, and whether it is consistent:
- **listener**. It means both the main conversation (Listener tab) and
  the Lisp tab's REPL ("Lisp listener" in its herald). *Inconsistent.*
- **buffer / file / scratch**. There are three scratch notions: the Lisp
  tab's `scratch.lisp`, the Code tab's language scratch buffers, and
  "scratch" as a Code tab side-pane. Defensible but confusing.
- **session**. A durable conversation (Sessions tab) versus a live session
  (the rail). The two are reconciled by "open as live tab".
- **agent / subagent**. Consistent: the Agents panel and the who-line dots.
- **Eval**. The composer's button says `Eval ⏎` but *sends text to the
  model*. The Lisp REPL's `RET` really evaluates. *Inconsistent, and this
  is the root of the "two systems" feeling.*

## 4. Visual consistency issues

- **V1 (P2).** Rule weights are ad hoc: `2px` (`--border`), `1.5px`, `1px`,
  and dashed variants appear at the same level of hierarchy in different
  panes. A pane boundary is 2 px everywhere, but inner separators are
  sometimes 1.5 px solid, sometimes 1 px dashed, sometimes 1.5 px dashed.
- **V2 (P2).** Font sizes drift: 0.7, 0.72, 0.74, 0.75, 0.78, 0.8, 0.82,
  0.85, 0.86, 0.88, 0.9, 0.92, 0.93 and 0.95em. Labels in title bars use
  0.75em in some places and 0.78em in others.
- **V3 (P2).** There are three "selected" treatments: the yellow `--select`
  fill, the yellow fill plus a 4 px inset bar in the tab colour, and an
  outline. They share no rule.
- **V4 (P1).** The Agents panel's empty state is a large empty
  constellation box with a lone black λ, plus a dashed hint. That is most of
  the panel showing nothing. The board's process-table idea fits better.
- **V5 (P1).** The "Ask the agent" buttons are ordinary blue primary
  buttons in four places (Code head, Lisp scratch, debugger, Code
  toolbar). The agent has no recognisable mark of its own. The critique
  board's first suggestion is a Clippy icon.
- **V6 (P1).** No monochrome theme is built in. The board shows one (`Mono`)
  and the brief asks that it be *more than the colour theme desaturated*.
  It should use inversion, stipple, hatching and line weight.

## 5. Interaction consistency issues

- **I1 (P0).** *Two prompts, two meanings of Eval.* In the Lisp tab, the
  REPL's `CL-AGENT>` and the main composer's `(C1)` are both on screen.
  Typing `(+ 1 2)` into the main composer sends the form to the model as
  a chat message. The environment does not understand its own language at
  its own prompt.
- **I2 (P1).** Lisp results and agent results are different kinds of
  artifact. A value printed in the Lisp tab is a presentation, but a value
  the agent mentions is text. Lisp entries never appear in the main
  listener.
- **I3 (P1).** Opening a file for editing means leaving the listener for
  the Code tab, then the Files pane. There is no `edit` at the prompt.
- **I4 (P2).** The who-line's `CL-AGENT:` is a fixed string, not the
  package the REPL is in.

## 6. Navigation and focus issues

- **N1 (P2).** Alt-L, Alt-C and Alt-S toggle a view and the Listener. Alt-L
  from the Lisp tab returns to the Listener, which is good, but there is no
  key for the Listener itself.
- **N2 (P2).** There is one Lem, shared between the Code tab and the Lisp
  tab's scratch. Each tab puts its buffer back on show (fixed on main in
  50f7f68). That works, but it is a reminder that "one editor" wants to be
  a pane of its own, not a property of two tabs. See §16.

## 7. Lisp-specific opportunities

- Forms typed at the main prompt are evaluated in the image, and the
  result is a presentation inline in the transcript (fixes I1, I2).
- An unfinished form at the main prompt means `RET` inserts a newline,
  as the Lisp REPL already does.
- The prompt itself says what `RET` will do: `(C n)` asks the agent,
  `CL-AGENT>` evaluates, `Command:` runs a command.

## 8. Agent-specific opportunities

- The process-table rendering of subagents (`AGENT 7  RUN  editing
  foo.lisp`) works as the Agents panel's primary list. The constellation
  should only appear once there is something to draw.
- A recognisable agent mark: Clippy, period-plausible and slightly
  tongue-in-cheek. Use it on every "Ask the agent" control.

## 9. Minibuffer / listener opportunities

This is the centre of the brief. The composer becomes a **Genera-style
listener prompt**, which reads what you type and decides:

| Input | Meaning | Prompt shows |
|---|---|---|
| `/name args` | a command | `Command:` |
| a Lisp form: `(…)`, `'x`, `` `x ``, `#'f`, `#(…)`, `#\c` (and only forms) | evaluate in the image | `CL-AGENT>` |
| `,anything` | force evaluation (`,*features*`) | `CL-AGENT>` |
| anything else | a request to the agent | `(C n)` |

- **Disambiguation.** The rule is syntactic: "only forms at top level".
  `(optional) fix the tests` contains bare words after the form, so it goes
  to the agent. `(defun f …) (f 2)` is all forms, so it is evaluated.
  `Alt-Enter` always sends to the agent, whatever the text looks like.
- **Feedback.** The prompt label, the send button (`Eval ⏎`, `Ask ⏎`,
  `Run ⏎`) and the mouse-doc line all change as you type, *before* you press
  Enter. Nothing is hidden.
- **Persistence.** Listener evaluations are ordinary Lisp REPL entries
  (source `listener`), so they also appear in the Lisp tab's transcript, and
  the agent reads them with the `lisp-scratch` tool's transcript. It is
  one image with one history.

## 10. Inspector opportunities

- Presentations in the main listener go to the same Inspect panel.
  Alt-click puts `(lisp-repl-object N)` at the main prompt, so a value can
  be used in the next form or mentioned to the agent.
- Later (P3): subagents and tool calls as inspectable objects in the same
  panel.

## 11. Colour-theme recommendations

- Keep both palettes. Light ("platinum") and dark ("night shift") are
  coherent and already token-driven.
- REFINE: use the agent's mark (Clippy) rather than the blue primary
  button to mean "the agent".

## 12. Monochrome-theme recommendations

Add a built-in `mono` theme, a 1-bit Lisp-machine look:
- black ink on white paper; title bars, selected tabs and selected rows
  shown by **inversion**;
- the dithered desk as a 50% stipple;
- every palette colour mapped to ink, so state is never carried by colour
  alone. Chips become ink-filled boxes, and "running" is a **hatch**
  pattern;
- syntax highlighting carried by weight and slant, not hue;
- the racing stripes as six 1-bit bands.

## 13. Accessibility findings

- **A1.** Focus rings exist (`:focus-visible` with a 2 px blue outline). In
  `mono` they must be ink, not blue.
- **A2.** State is mostly colour plus text (chips carry words), which is
  good. The who-line agent dots are colour-only and have a `title` but no
  text alternative.
- **A3.** The main pane's prompt label changes meaning silently today (only
  for `/`). Once it carries three meanings it needs an accessible name:
  `aria-label` on the input updated with the mode.
- **A4.** Hit targets: `.btn-small` and `.btn-tiny` are about 18 px tall,
  acceptable for a dense expert UI but under the 24 px guideline.
  Recorded, not changed.

## 14. Proposed design principles

1. **The prompt understands the environment's language.** Forms
   evaluate, commands run, and prose goes to the agent.
2. **Say what will happen before it happens** (the prompt and button
   labels).
3. **Every computed value is a presentation.** If you can see it, you can
   inspect it.
4. **State never rides on colour alone.** Every theme must survive `mono`.
5. **The agent is a process with a face.** Use one mark and one
   vocabulary (RUN / WAIT / DONE).
6. **Density stays.** Hierarchy comes from rules, inversion and type, not
   whitespace.

## 15. Prioritized changes

Each change below is described as **Problem · Evidence · Change · Why ·
Risk · Scope**.

**P0 · REDESIGN · Unified listener prompt** (I1, I2)
- **Problem:** the composer sends Lisp to the model.
- **Evidence:** composer.js `submit()` always calls `send`; the button says Eval.
- **Change:** the input classification in §9; forms evaluated via
  `/api/lisp/eval` with `source: listener`; entries rendered inline with
  the Lisp tab's renderer.
- **Why:** this is the brief's central idea.
- **Risk:** misclassifying prose that starts with `(`. This is mitigated by
  the all-forms rule, the live prompt and Alt-Enter.
- **Scope:** composer.js, render.js, lisp.js (export the entry renderer),
  and a new listener-forms module.

**P1 · REFINE · `edit` at the prompt** (I3)
- **Problem:** editing a file means leaving the listener.
- **Change:** `/edit PATH[:LINE]`, with `@path` completion, opens the file
  in the Code tab's Lem.
- **Risk:** low.
- **Scope:** main.js / code.js client command.

**P1 · REFINE · The agent's mark** (V5)
- **Change:** a 64 px Clippy, downsampled from the owner's pixel-art
  icon, drawn at 1.4em. It goes on every "Ask the agent" control, with the
  text kept for clarity and screen readers.
- **Risk:** low.
- **Scope:** app.css (as a data URI, since assets are text) plus the four
  call sites.

**P1 · REDESIGN · Built-in `mono` theme** (V6, §12)
- **Risk:** stray colour-only states. Audit them with screenshots.
- **Scope:** theme.css, plus a mono block in app.css.

**P1 · REFINE · Agents panel: process table first** (V4, §8)
- **Change:** a table with id, state word, elapsed time, current operation
  and model. The constellation only appears with subagents.
- **Scope:** agents.js, app.css.

**P2 · REFINE · Who-line package** (I4)
- **Change:** show the REPL's real package, updated on `lisp-entry`.

**P2 · REFINE · Rule and type tokens** (V1, V2, V3)
- **Change:** add `--rule-thin` and `--rule-mid` and a small type scale
  (`--fs-label`, `--fs-small`, `--fs-meta`), and use them where the same
  role is drawn differently. Do not sweep every value: only the roles.

**P3 · EXPERIMENT**
- subagents and tool calls in the inspector;
- a `Clear Window`-style form-feed rule in the listener.

---

## 16. Sketch: Lem as one of the listener's panes, and toward a cl-agent frontend for Lem

The owner asked for a front end for Lem sketched from the current work. Where
things stand:
- Lem runs inside cl-agent's image, with its display as lem-server's
  JSON-RPC renderer.
- Lem's own web client draws it in iframes (`lem-view.js`).
- The agent drives Lem with `lem-command`, and the Lisp tab's scratch has a
  Lem minor mode.

The direction, in steps that each stand alone:

1. **One editor pane, not two tabs' editors** (next). Make the Lem view
   a single element that moves between hosts instead of one iframe per
   tab. Moving an iframe reloads it, so the host *overlays* the iframe on
   whichever pane wants it, positioned over that pane's rectangle. That
   leaves one connection and one size, with no buffer races. This is the
   Genera arrangement: the editor is one window that comes forward.
2. **The listener can call the editor** (done in this pass: `/edit`).
   Later, `M-x` at the main prompt runs a Lem command
   (`/api/lem/run`), and `C-x C-f` at an empty prompt opens find-file.
3. **The editor can call the listener.** In Lem, a `cl-agent-ask` command
   (`C-c C-a`) sends the region or the form at point to the main
   listener as a question with that text as context. The answer arrives
   in the listener, and the presentations in it are inspectable.
4. **A cl-agent frontend class for Lem.** Lem's frontends are classes
   implementing `lem-if:*` generics (ncurses, sdl2, server). cl-agent
   already subclasses lem-server's `jsonrpc` (`lem-host-display`).
   The next step is to render Lem's windows **with cl-agent's own DOM**
   (rules, fonts, presentations) instead of lem-server's canvas client:
   - `lem-if:render-line` and its kin send styled spans;
   - the page draws them in a pane that follows the theme exactly,
     `mono` included.

   This lets Lem buffers carry presentations (a value in a buffer can be
   clicked to inspect it) and makes Lem's minibuffer *the same input
   line* as the listener. The "one listener" endpoint is a single prompt
   that reads forms, commands, prose and editor keys. That is a large
   step, and should come after (1)–(3) prove the model.

What stays: the MCP server, ACP, CLI and TUI are unaffected by all of
this. They talk to the same session and tools, not to the page.

---

## Implementation log

### Pass 1: the listener reads Lisp, and the agent's mark, mono theme and process table

- **Unified prompt** (`lisp-read.js`, `forms.js`, composer.js).
  Classification is syntactic and lives in a DOM-free module, so the test
  suite runs it under node (`the-prompt-tells-a-form-from-a-request`).
  - Forms POST to `/api/lisp/eval` with `source: "listener"`. The entries
    are drawn with the Lisp tab's own renderer (`lispEntryNode`), given a
    context, so Alt-click inserts at the main prompt and Esc in the debugger
    returns there.
  - Each entry is remembered with the turn it was typed in, so a full
    re-render puts it back in place. `render.js` gained a `turnExtras` hook
    for that, rather than forms.js poking the DOM after every render.
  - *Rejected*: evaluating bare symbols. In Genera `foo` RET evaluates
    `foo`, but here "hi" or "thanks" would land in the debugger. A leading
    comma (`,*features*`) covers the bare-symbol case explicitly.
  - *Known edge*: a question wrapped entirely in parentheses —
    `(why does (car nil) work?)` — reads as a form. The prompt shows
    `CL-AGENT>` before Enter, and Alt-Enter sends it to the agent.
- **The agent's mark.** The owner's pixel Clippy is downsampled to 64 px
  and quantised to 48 colours (2.8 KB), then stored as `--agent-mark` in
  theme.css. Web assets are text-only, so it has to be a data URI. It
  appears on every Ask button and on the send button whenever Enter will
  ask. The labels became "Ask", with the full sentence kept in
  `aria-label` and the mouse-doc.
- **mono theme.** It lives in theme.css plus a "mono" block in app.css,
  which handles inversion for selection, a hatch for running, a double
  rule for danger and weight or slant for syntax. Lem follows it, because
  the page now tells Lem light or dark from the theme's `color-scheme`
  rather than its name.
- **Process table** in the Agents panel. The constellation only appears
  once there are subagents.
- The who-line shows the REPL's real package.
- *Observed, not changed*: the Code tab's toolbar path (`direction: rtl`)
  sometimes renders empty although its text is there. This happened
  before this pass as well.

### Pass 2: the listener and the editor call each other (section 16, step 2 and part of 3)

- `/edit @path[:line]` and `/mx [command]` at the main prompt open a file,
  or run a Lem command, in the Code tab's Lem. `/mx` switches the tab to
  Lem first, because Lem's prompts are answered in its own view.
- `C-c C-a` in Lem (`cl-agent-ask`, `src/lem/listener.lisp`) puts the
  region, or else the top-level form at point in a Lisp buffer, at every
  open page's main prompt, with file and lines. It never sends: the prompt
  is the person's. The command publishes from Lem's helper thread
  (`lem-in-background`), because pages are other code's to lock.
- *Rejected*: sending the question straight away. The person has not said
  what they want to know, and an empty "About lines 3–9:" request wastes a
  turn.

