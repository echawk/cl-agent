# Lem, transparently: a cl-agent front end for Lem

Status: **plan**. Nothing below is built yet except Stage 0. Each stage
can be merged on its own, behind a setting where it says so, and each
leaves the editor working.

The goal: Lem is how cl-agent edits, but the person never has to think
"I am in Lem now." There is one theme, one font and one set of
presentations. There is one prompt line, and the editor's prompts are the
listener's prompt. There is no iframe, no second visual language, and no
"Starting Lem…" moment. Lem's keys, commands, modes and the user's init
file all keep working: the transparency is in how it looks and behaves,
not in what it can do.

## Where we are (Stage 0, done)

- **Lem runs inside cl-agent's image** (`src/lem/host.lisp`). Its display
  is `lem-host-display`, a subclass of lem-server's JSON-RPC display
  (`src/lem/display.lisp`).
- **Lem's own web client draws it**, in one iframe positioned over
  whichever tab shows Lem (`static/lem-view.js`).
- **The agent drives Lem** with `lem-command`, through a minibuffer
  bridge (`src/lem/commands.lisp`).
- **The listener and Lem call each other.** `/edit`, `/mx` (with
  completion) and `C-c C-a` connect them, and the Lisp tab's scratch
  buffer has a Lem minor mode.
- **The cold start is fixed.** Requests waiting while Lem started were
  woken one at a time, so most slept 30 s. The diagnosis is in
  `docs/ui-ux-review.md`, "Lem's slow cold start".

**What still makes Lem visible as a separate thing:**
1. **The iframe.** Lem draws on its own canvas, in its own fonts and
   chrome.
   - The page pushes a colour theme into Lem rather than Lem simply
     *using* the page's CSS.
   - The `mono` theme, presentations, the who-line's mouse documentation
     and right-click menus all stop at the iframe's edge.
2. **Two prompts.** Lem's minibuffer (`C-x C-f`, `M-x`, `query-replace`)
   is a line inside the iframe, not the page's prompt.
3. **Two status lines.** Lem's mode line and echo area duplicate the
   who-line.
4. **The Lem | Simple switch** names an implementation, not a choice the
   person cares about.
5. **No terminal or shell.** There's no way to run a command on a file
   (compile a scratch buffer, run tests) next to it.

## The seam: lem-server's display protocol

Lem's frontends are classes implementing the `lem-if:*` generics. lem-server's
implementation turns every drawing call into a JSON-RPC notification over a
websocket, which its web client (`frontends/server/frontend/editor.js`, about
1500 lines, canvas) renders. The messages it handles are:

| Group | Messages |
|---|---|
| Views | `make-view`, `delete-view`, `resize-view`, `move-view`, `change-view`, `clear`, `redraw-view-after` |
| Drawing | `put`, `modeline-put`, `clear-eol`, `clear-eob`, `move-cursor`, `update-display`, `bulk` |
| Display | `resize-display`, `update-foreground`, `update-background`, `update-cursor-shape`, `set-font`, `get-font`, `get-display-size`, `load-css` |
| I/O | `get-clipboard-text`, `set-clipboard-text`, `js-eval`, `exit` |

Input goes the other way as `input` (key and mouse events), `redraw`
(with a size) and `login`.

**The plan keeps the server side** (Lem plus lem-server's display, which
is already ours to subclass) and **replaces the client** with
cl-agent's own renderer, a DOM module in the page. A protocol, rather than a
fork, is what makes this tractable:
- Lem's drawing logic stays upstream's.
- Upgrades to Lem keep working.
- Only the last mile, pixels, becomes cl-agent's.

---

## Stage 1: a screen model and a recorded protocol (test harness first)

**Why first:** every later stage changes how Lem is drawn. Without a way
to check "the screen says what the buffer says" outside a browser, each
stage would only be testable by screenshot.

**Work**
- **`lem-screen.js`**, a pure module with no DOM. It folds protocol
  messages into a *screen model*: views, each a grid of lines; each line a
  list of `{text, attribute}` runs; the cursor; the mode line.
  - It handles `make-view`, `put`, `modeline-put`, `clear-eol`,
    `clear-eob`, `clear`, `move-cursor`, `bulk`, `resize-view` and
    `delete-view`.
  - The later renderer draws from this model. It never interprets the
    protocol itself.
- **A recording display** (test-only, `t/`): a `lem-host-display` subclass
  whose `notify` also appends each message to a list. A test can then run
  Lem commands and get the exact message stream.
- **`lem-screen-text`** in Lisp: the same fold, enough to turn a recorded
  stream into the text of each view. This is the oracle the JS model is
  checked against.

**Testing notes**
- *Lisp:*
  - Open a file.
  - Run `next-line`, `end-of-line`, `insert-string`, `split-active-window`
    and `query-replace`.
  - Check that `lem-screen-text` of the recorded stream equals each
    window's visible buffer lines, and the mode line text Lem computes.
  - Include a long line (wrapping), a tab, a wide character (CJK), and an
    empty buffer.
- *Golden streams:* save two or three recorded streams as fixtures
  (`t/fixtures/lem-*.jsonl`).
- *JS:*
  - Run under node, as `the-prompt-tells-a-form-from-a-request` does.
  - Feed each golden stream to `lem-screen.js` and compare its text grid
    with `lem-screen-text`'s.
  - The same input must give the same screen.
- *Upgrade guard:* re-record the golden streams when Lem is bumped. A
  changed message shape fails here, not in the browser.

**Risk:** low, since nothing user-visible changes. `bulk` nesting and
`put` with attribute caching (`clear-attribute-hash-cache`) are the
subtle parts.

## Stage 2: cl-agent's renderer, behind a setting

**Work**
- **`lem-pane.js`** opens the display's websocket itself: no iframe, the
  same JSON-RPC, same `login` with a size measured from the pane, same
  `redraw` on resize.
  - It feeds `lem-screen.js`.
  - It renders each view as a block of line elements made of spans, in
    the page's font, at the page's size.
- **Attributes become CSS, not colours.**
  - lem-server sends resolved colours. The display subclass should also
    send the attribute's *name* (`syntax-keyword-attribute`,
    `region`, `modeline`, …).
  - The renderer then maps names to the page's own classes (`sx-keyword`,
    `::selection`-like region, …), and the theme, `mono` included, applies
    with no theme push.
  - Unknown attributes fall back to the sent colours.
- **Input:**
  - Port the key translation from Lem's `keyevent.js` (Ctrl, Meta, IME
    composition, dead keys, paste) into the pane.
  - Focus behaves like any other pane: Tab order, `focus-visible`.
  - Mouse: click to move point, drag for a region, wheel scrolling (the
    protocol's mouse events).
- **The cursor** is drawn by the renderer, with an inverted cell as in
  Genera, and in mono too.
- **A setting:** `:lem-renderer :page | :frame`, defaulting to `:frame`
  in this stage. Both renderers share the server and can be switched at
  runtime for comparison.

**Testing notes**
- *Equivalence:* with both renderers open on the same file, the text of
  every visible line in the DOM equals `lem-screen.js`'s model, which
  equals Lem's buffer (Stage 1 oracle).
  - Do this through the browser harness: query `textContent` per line.
- *Keys:*
  - Type, then `C-x C-s`, and read the file from disk.
  - `C-g` cancels; `M-x` opens Lem's prompt; IME input lands once; paste
    lands once.
  - `C-/` undo.
  - Arrow keys and Home/End in a wrapped line.
- *Themes:*
  - Screenshot light, dark and mono.
  - In mono, nothing coloured remains: assert every computed colour in
    the pane is black or white.
- *Resize:*
  - Drag the splitter.
  - Hide and show the side panes.
  - Switch between the Code tab and the Lisp tab's scratch.
  - Lem's width in columns follows, with no line drawn at the old width.
    The 0×0 guard (`lem-display-sane-login`) still applies.
- *Performance:*
  - Hold down a key in a 5000-line file. The frame budget is under 16 ms
    per `update-display` on a typical laptop; measure with
    `performance.now()` around the render.
  - Re-render only changed lines, which the model knows from `put`
    targets.

**Risk: medium.** Key translation is where web editors go wrong. Port Lem's
logic rather than rewriting it, and keep `:frame` until the key tests pass.

## Stage 3: make it the default; the editor is just "the editor"

**Work**
- Default `:lem-renderer` to `:page`.
- **Retire the iframe overlay.** `lem-view.js`'s slot positioning goes:
  the pane is an ordinary element, mounted where it is needed. The
  Code tab and the Lisp tab's scratch each mount it.
  - There is one Lem window layout per mount: the scratch pane shows
    Lem's window for the scratch buffer.
  - Two simultaneous views would need Lem frames, but lem-server
    disables Lem's `frame-multiplexer` ("cannot be used with
    lem-server", `frontends/server/main.lisp`). So the pane is one shared
    view that each tab mounts in turn, as the iframe is today. Each tab
    puts its buffer back on show.
- **Rename the switch.** "Lem | Simple" becomes **Editor | Plain**. Plain
  is the simple editor, kept as the user asked. The word "Lem" leaves the
  UI except in Help, the keymap, and the init-file documentation.
- **"Starting Lem…" goes.** Lem starts with the image (warm, in the
  background) instead of on first use, now that start-up is about
  0.1 s and correct.

**Testing notes**
- All Code tab and Lisp tab browser checks from passes 1–5 rerun with
  `:page`:
  - `/edit`, `/mx`, `C-c C-a`;
  - the agent's `open-in-editor` and `lem-command` edits appearing live;
  - copilot ghost text;
  - the scratch minor mode's `C-c C-c` / `C-x C-e` / `C-c C-k`.
- Cold start: the page shows an editable buffer within 1 s, every run, on
  three fresh servers.
- Live sessions: switching tabs keeps each session's file.
- `make test` plus the Stage 1 golden streams.

**Risk: medium.** The shared-view decision affects the Lisp tab.

## Stage 4: presentations in the editor

**Work**
- The renderer already knows each run's attribute name (Stage 2). Some
  runs become presentations (`objects.js`):
  - a Lisp symbol in a Lisp buffer, giving Describe, Find definition,
    Inspect its value, and Ask the agent about it;
  - a file path, giving Open and Inspect;
  - a diagnostic's underline, giving the diagnostic object;
  - a URL.
- Lem marks them with a text property. The display subclass adds a
  `presentation` field to a `put` run when the run carries one. Lem's own
  syntax scanners already find symbols and paths; reuse them.
- **Right-click** inside the editor opens the object's menu. **Left-click**
  moves point, as an editor must; the who-line says "R: menu" over a
  presentation.
- **Region as an object:** right-clicking a marked region opens the
  selection menu (Ask, Evaluate, Copy), as in the listener.

**Testing notes**
- *Lisp:* a buffer with `(defun foo () (bar))` sends runs where `foo`
  and `bar` carry presentation data, and a string literal does not.
- *Browser:* right-click `bar` and see a "Symbol BAR" menu whose Describe
  puts `(describe 'bar)` at the prompt.
- *Keyboard:* the Menu key at point opens the menu of the presentation
  under the cursor.
- *Mono:* the presentation hover box is visible.

**Risk:** low to medium, mostly about which runs deserve to be objects.
Start with symbols and paths.

## Stage 5: one prompt — Lem's minibuffer is the listener's prompt

**Work**
- When Lem prompts (`prompt-for-string`, `prompt-for-file`, `M-x`,
  `query-replace`, `y-or-n-p`), the page's main prompt becomes that
  prompt:
  - its label is Lem's (`Find file:`);
  - its completion comes from Lem's completion function;
  - Enter answers, and `C-g` or Esc cancels.
  - Lem's own minibuffer line is not drawn.
- **Mechanism:** this is the minibuffer bridge the agent already uses
  (`src/lem/commands.lisp`), turned toward the person. The display
  subclass reports "Lem is prompting: label, initial text, completion
  kind", and the page answers with the text. Completion requests go to a
  new `/api/lem/complete`, which calls the prompt's completion function.
- **Messages:** `lem:message` goes to the who-line's documentation layer
  for a moment, as `mousedoc` already does. Lem's echo area is not drawn.
- **Mode line:**
  - Each view keeps a thin mode line (file, modified mark, mode,
    line:column), drawn in the page's style.
  - Lem's mode-line format still decides what is in it, so a user's
    customisation keeps working.

**Testing notes**
- `C-x C-f` in the editor:
  - focus jumps to the main prompt, labelled `Find file:` and holding
    the buffer's directory;
  - Tab completes from Lem;
  - Enter opens the file in the editor, and focus returns.
- `M-x`: completion lists Lem commands, the same list `/mx` uses.
- `query-replace`:
  - two prompts in sequence, then `y`/`n`/`!` keys go to Lem;
  - the prompt shows Lem's question.
- `C-g` mid-prompt: Lem's command is cancelled, and the prompt returns to
  `CL-AGENT>`.
- The agent's `lem-command` still answers its own prompts. The bridge
  must tell "the agent asked" from "the person asked"; it already marks
  the agent's.
- vi-mode init file: `:` in normal mode uses the same prompt.

**Risk: high.** Prompts are where editor state and page focus can
disagree. Keep a fallback (draw Lem's minibuffer as before) behind a
setting until this has been used for a while.

## Stage 6: a shell and a terminal next to your files

The aim: run a command on a file without leaving cl-agent, such as
compiling and running a C scratch buffer or running a test suite, with
the output an object you can inspect and ask about.

**6a. A shell, with no native build: Lem's `shell-mode`**
- `lem-shell-mode` runs a shell in a buffer (comint-style) through
  `lem-process`, which uses `async-process`.
  - ocicl's async-process ships prebuilt libraries (`static/`) for macOS
    arm64 and x86_64 and for Linux aarch64 and x86_64, glibc and musl, so
    this works with no compiler.
  - Add `lem-shell-mode` to the system's dependencies.
- In the UI:
  - **Shell here** (Code tab, and the file object's menu) opens a shell
    buffer in the file's directory.
  - `/shell [dir]` at the prompt does the same.
  - The shell buffer is an ordinary editor buffer, so the renderer,
    presentations and the agent's `lem-command` all apply.
- **Run this file:**
  - A per-language command table in `config.lisp`, for example:
    ```lisp
    :run-commands (("c"      . "cc -Wall -o /tmp/a.out {file} && /tmp/a.out")
                   ("python" . "python3 {file}")
                   ("lisp"   . nil))   ; nil: C-c C-k
    ```
  - `C-c C-r` in the editor, or the **Run** item in a scratch buffer's
    menu, saves the buffer and sends the command to its shell buffer.
  - The output becomes a presentation of a *run* object: command, exit
    status, output, and duration. "Ask the agent about it" then works
    on a failing compile.

**6b. A real terminal — done, and then replaced by slt**

A terminal was wanted soon, so 6b was built first, in the iframe view, on
Lem's own `lem-terminal` over libvterm. It has since been replaced by
[slt](https://github.com/echawk/slt), a terminal emulator in Common Lisp,
in a **Terminal tab of its own**: a separate frontend, not a Lem buffer
(`src/terminal.lisp`, `static/terminal.js`, tests in
`t/test-terminal.lisp`).
- slt runs in cl-agent's image with its pure-Lisp `lispvt` engine, so no
  native build is needed. Its web frontend is subclassed so that every
  terminal shares one socket server (127.0.0.1, a random token per
  terminal, local pages only). Its browser client (`slt-terminal.js`)
  draws each terminal in the page's theme and font.
- slt is a git submodule, `third-party/slt`, pinned to one commit.
- `/term`, `/run`, Ask (Ctrl-Shift-A) and the agent's `terminal-output`
  work as they did. In a terminal every key is the program's: the page's
  Alt- keys step aside.
- What standalone slt does not need, cl-agent does:
  - It reaps a closed terminal's shell. slt sends SIGTERM, which an
    interactive shell ignores, and then quits; cl-agent lives on.
  - It starts a shell at the page's size, so that `/run`'s first output
    is not wrapped at 80 columns.
  - It keeps an exited terminal's last screen to read and ask about.
- Lem's `M-x terminal` is gone from the hosted Lem: the libvterm shim, its
  patches and its build are removed.

Still open from 6:
- The *run object*: a run's command, exit status and output as a
  presentation. slt's prompt marks (OSC 133) could supply the boundaries
  once the shell emits them.
- 6a, Lem's `shell-mode`, is no longer needed for running files.

**Testing notes**
- *6a, shell:*
  - Open a shell in a scratch directory and send `echo hi` RET; the
    buffer contains `hi`.
  - **Run this file** on a C scratch buffer with a syntax error. The run
    object's exit status is non-zero, its output contains the compiler's
    message, and "Ask the agent about it" puts both at the prompt.
  - A long-running command (`sleep 5; echo done`) does not block Lem's
    editor thread: other buffers stay editable meanwhile.
  - Killing the buffer kills the process.
- *6b, terminal (slt; `t/test-terminal.lisp` covers each):*
  - Open one in a directory whose name needs quoting; `pwd` shows it.
  - `sleep 30`, then Ctrl-C as the client sends it: the prompt is back
    within 3 s, even right after a full GC.
  - `/run` on a C file: compiled, run, and `$?` is the program's.
  - Closing hangs up and reaps the shell; an exited shell keeps its last
    screen.
  - The socket refuses a wrong token and a page from elsewhere.
  - In a browser: keys typed, Alt-L staying in the terminal, Ctrl-Shift-A
    asking, the size filling the pane, theme switches.
- *Tests must never touch the user's shell configuration:* run shells
  with `HOME` and `ZDOTDIR` pointed at the test's config directory.

**Risk:**
- 6a: low to medium. async-process's prebuilt libraries need checking
  per platform.
- 6b: medium. It means native builds and key ownership.

## Stage 7 (later): the TUI and the agent's view

- The terminal UI (`--ui tui`) could host Lem through a terminal
  frontend (Lem's ncurses frontend, or a lem-if implementation over
  tuition). This is out of scope while the web UI is the frontend that
  matters (`docs/lem-integration.md`).
- **The agent's view of the screen:** with the Stage 1 model in Lisp,
  a tool can show the agent exactly what the person's editor shows
  (window layout, point, visible lines). That helps it answer "what am I
  looking at?" without re-reading whole files.

---

## Order, and what each stage unlocks

| Stage | Unlocks | Depends on | Size |
|---|---|---|---|
| 1 screen model + recordings | testing everything after | — | S |
| 2 page renderer (opt-in) | themes, mono, fonts inside the editor | 1 | L |
| 3 default; retire iframe | "Lem" disappears from the UI | 2 | M |
| 4 presentations in buffers | inspect and ask from inside the editor | 2 (3) | M |
| 5 one prompt | the editor's prompts are the listener's | 3 | L |
| 6a shell + Run this file | compile and run scratch files | 3 (works with 2) | M |
| 6b terminal | full-screen programs, a real shell | — (done: slt, the Terminal tab) | M |

6a can go before 2 if a shell is wanted sooner: it is an ordinary buffer
and works in today's iframe view too. 6b depends on the key-ownership
rule, which is easier once the editor is a page element (Stage 2), but
could also be done in the iframe.
