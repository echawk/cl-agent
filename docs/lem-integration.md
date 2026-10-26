# Lem as cl-agent's editing engine: integration plan

Status: **partly implemented.**
- Implemented: §4.1–4.3 (Lem pinned through ocicl and hosted without a display, in `src/lem/host.lisp`), §4.8's init-file loading, §4.9 (micros self-connection off), and §7's highlighting (`src/lem/highlight.lisp`) of reply code blocks and of the Code tab's scratch buffers (`src/scratch.lisp`, `static/code.js`).
- Also implemented: files are opened, edited and saved through Lem buffers (`src/lem/files.lisp`, the Code tab), with Lem's find-file mode detection and hooks, `save-buffer`, directory listing and file-name completion. Edits sync as text into the buffer; Lem's own lsp-mode is kept off in favour of cl-agent's language servers.
- Also implemented: **the Code tab's editor is Lem itself** (`src/lem/display.lisp`, §9). The hosted Lem's frontend class is now lem-server's renderer, and Lem's own web client runs in an iframe. Your keys, `M-x`, the minibuffer, windows and dired are all real Lem.
- Also implemented: **the agent runs Lem's commands** through a minibuffer bridge (`src/lem/commands.lisp`, the `lem-command` tool, §10).
- Also implemented: **the Lisp tab's scratch buffer can be edited in Lem** (`src/lem/lisp-scratch.lisp`, `static/lem-view.js`). A minor mode, `cl-agent-scratch-mode`, sends `C-c C-c` / `C-x C-e` / `C-c C-k` to the Lisp tab's REPL, and saves the buffer as it is edited. The one Lem is shared by both tabs: each puts its own buffer in Lem's window when it is shown, and a visit that lands after the tab was left is dropped. Lem's tab bar is off by default (`*lem-tab-bar*`), and the user's init file can turn it back on.
- Not yet: the composer and the Lisp tab's REPL input are still cl-agent's own editors.
- **Terminal:** not Lem's any more. The Terminal tab runs [slt](https://github.com/echawk/slt) (`src/terminal.lisp`): `/term`, `/shell`, Ctrl-Shift-A to ask about it, and the agent's `terminal-output`.
- **Next:** `docs/lem-frontend-plan.md` stages cl-agent's own renderer for Lem's display protocol, with the goal that Lem is transparent. The stages are: a screen model and recorded streams, then a page renderer, then retiring the iframe, presentations in buffers, one prompt, and a shell and terminal. Each has testing notes. The terminal UI is out of scope: the web UI is the frontend that matters.

This plan covers two things:
- How cl-agent would load [Lem](https://github.com/lem-project/lem) into its own image as a library. Lem would drive cl-agent's text inputs (the composer, the Lisp REPL input and the scratch buffer) with Lem's editing commands, keymaps and modes, configured by the user's own Lem init file.
- How Lem would then syntax-highlight Markdown and code in the transcript by language, so a C block highlights as C (section 7).

Lem citations are `path:line` in the upstream repository, github.com/lem-project/lem, at commit `887b7b4f` (2026-06-28). Lem's internals move, so re-check each citation when pinning a newer commit.

---

## 1. Goal

- **Editing behaviour comes from Lem.** Keys typed into a cl-agent input box run Lem commands on a Lem buffer. If the user's init file enables vi-mode, the composer is modal. If it rebinds `C-w`, that binding applies here too.
- **The look stays cl-agent's.** The web page keeps rendering its own editors (`lisp-editor.js`, `composer.js`) with its own highlighting, completion menu and echo area. Lem supplies the text, cursor, mark and messages; it does not draw the page.
- **The user's configuration is honoured.** That means the init file Lem itself would load, found by the same lookup and read in the same package.
- **It is optional.** A setting chooses between `:builtin`, today's editors, and `:lem`. If Lem fails to load or start, cl-agent falls back to the built-in editors and says why.

A user without an init file gets Lem's defaults (Emacs keys) plus their saved history. Anything added to the init file later is picked up.

---

## 2. Options considered

| Option | What it is | Verdict |
|---|---|---|
| **A. Embed Lem's own web frontend** | Run `lem-server` (`frontends/server/`) and show its canvas client in an iframe or panel. | **Rejected for text inputs.** It is a whole editor screen, not an input box, so our completion, submit and echo area would be lost. Problems with it in our image:<br>- It starts a **second web server** (clack + hunchentoot) on its own port (`frontends/server/main.lisp:875-893`).<br>- It **broadcasts** one display to every client (`main.lisp:142-153`).<br>- Its `invoke` busy-waits (`main.lisp:208-212`).<br>- It installs an exit hook that calls **`(uiop:quit 0)`** (`main.lisp:232-235`).<br>- It requires `lem/extensions`, all ~70 modes.<br>- Its JS client hard-codes `#lem-editor` and keeps re-focusing a hidden `<input>` on blur (`frontend/editor.js:92-94, 959-961`), which would take focus from our other inputs.<br>It could become a separate "open in Lem" pane later. |
| **B. Lem's core runs inside cl-agent with no display of its own; cl-agent's UI renders** | Load `lem/core` plus the chosen modes. Implement a minimal Lem frontend class that draws nothing. Run Lem's editor thread ourselves. The page sends keys in, and buffer state flows back out. | **Chosen.** Users get Lem's commands, keymaps, modes and init file, and cl-agent keeps its UI, completion and protocol. |
| **C. Run cl-agent inside Lem** | cl-agent as a Lem extension, like Lem's own `extensions/claude-code`. | Not what is asked here, since it would make Lem the host application. Worth noting for Lem users, though: cl-agent's agent loop is frontend-neutral (`src/ui/frontend.lisp`), so a Lem frontend for cl-agent could be written later. |

The rest of this document describes option **B**.

---

## 3. Facts about Lem that shape the design

**Systems**
- `lem/core` (`lem.asd:17-232`) is the editor without a frontend: buffers, points, commands, keymaps, modes, windows and frames, prompts, completion and isearch.
- Its dependencies include `micros` (Lem's fork of swank), `log4cl`, `dexador`, `yason` and `lem-mailbox` (`lem.asd:18-43`).
- `lem/extensions` (`lem.asd:234-301`) pulls in about 70 modes, some with FFI (terminal, tree-sitter). We load individual mode systems instead.

**One global editor**
- There is one event queue, `*editor-event-queue*` (`src/event-queue.lisp:3`).
- `*current-buffer*`, `*current-global-mode*`, `*implementation*` and the buffer list are all globals.
- The editor thread is found **by name**: `find-editor-thread` looks for a thread named `"editor"` (`src/lem.lisp:90-93`).

**Starting**
- `launch` (`src/lem.lisp:98-137`) changes global state that we must not let it touch in cl-agent's image:
  - **it reconfigures log4cl's root logger** (`:105-114`);
  - it sets `sb-impl::*default-external-format*` (`:103`).
- `run-editor-thread` (`:74-88`) does the real work:
  - starts a thread named "editor";
  - inside it, binds the standard streams (`with-editor-stream`, `src/macros.lisp:43-53`) and runs `setup` (first frame, syntax scanner, the `*this-command-keys*` input hook, `:23-34`);
  - then calls `toplevel-command-loop` with `(init args)`.
- `init` (`:67-72`) runs `*before-init-hook*`, then `load-init-file`, then `*after-init-hook*`, then `apply-args`. With no files given, `apply-args` opens the splash screen.

**Getting work onto the editor thread**
- Lem's own background threads hand work to the editor thread by queuing an event with `send-event`, never by taking a lock. Examples: timers (`src/lem.lisp:18-22`) and `call-background-job` (`src/interp.lisp:155-177`).
- The model to copy is `execute-in-editor` in `extensions/mcp-server/server.lisp:273-297`. It queues a lambda with `send-event` and waits on a condition variable for the result.

**Keys**
- A key is `(defstruct key ctrl meta super hyper shift sym)` (`src/key.lisp:22-28`), built with `make-key` (`:51-79`).
- `execute-key-sequence` (`src/input.lisp:253-260`) runs keys only until its list is used up. A prefix key, a prompt or a pending vi operator then **blocks waiting on the global queue**. So it must never be called from an HTTP thread. Keys go through `send-event` into the real command loop instead.

**Watching changes**
- Changes are reported through `after-change-functions` (start, end, old-len), which buffers can set locally (`src/buffer/internal/buffer-insert.lisp:9-10,153-161`). Add a hook with `(add-hook (variable-value 'after-change-functions :buffer b) fn)`.
- **There is no hook for cursor moves.** Use `*post-command-hook*` (`src/command.lisp:5`) or our frontend's `update-display`, which runs at the end of every redraw (`src/display/base.lisp:71`).
- `position-at-point` is **1-based** (`src/buffer/internal/basic.lisp:382-394`). JavaScript's `selectionStart` is 0-based.

**Keymap precedence**
- `other-keymaps` (`src/keymap.lisp:552-568`) gives priority to the special keymap first, then the global mode's `compute-keymaps`, then the major mode at point, then the buffer's active modes.
- vi-mode's `compute-keymaps` (`extensions/vi-mode/core.lisp:168-178`) lists **buffer minor-mode keymaps before vi's state keymaps**.
- So a cl-agent minor mode's binding for Return beats both vi and Emacs bindings.

**The init file**
- `lem-home` (`src/config.lisp:3-8`) is `$LEM_HOME`, otherwise a `.lem` directory in the user's home if one exists, otherwise `lem/` under the XDG config directory.
- `load-init-file` (`src/lem.lisp:43-55`, internal) loads `init.lisp` from there, or else a `.lemrc` in the user's home, plus a `.lemrc` in the current directory when that isn't the home directory. It reads them in package `LEM-USER`.
- `config.lisp` and `history/` in lem-home are **written by Lem** (`src/config.lisp:13-40`; isearch `src/ext/isearch.lisp:101-108`; themes `src/color-theme.lisp:113-114`).

**lisp-mode and micros**
- Turning lisp-mode on in a buffer runs `self-connect` (`extensions/lisp-mode/lisp-mode.lisp:68, 230-239`).
- That starts a **micros server on a random localhost port inside the same image** and connects to it. `lem-lisp-mode/test-api:*disable-self-connect*` turns this off.

**Package locks and names**
- `LEM`, `LEM-CORE` and `LEM-RESTART` are package-locked.
- Nicknames to watch: `LEM-IF`, and **`LSP`**, defined by lsp-base, which lisp-mode loads.
- Lem uses `micros`, so there is no clash with the `slynk` cl-agent now loads.

**Licence:** MIT (`LICENCE`).

---

## 4. Design

### 4.1 Dependencies and loading

1. **Pin Lem by git commit in `ocicl.csv`**, the same way the `git+https://github.com/lambda-symbolics/...` entries are pinned. ocicl's own `lem` package is the 2025-08-10 build, older than the commit studied here.
   - Lem's `qlfile` pins `micros`, `lem-mailbox` and `lem-extension-manager` from git. ocicl has builds of all three, plus `inquisitor`, `cl-mustache`, `log4cl` and `esrap` (checked with `ocicl list`).
   - For each dependency, compare the ocicl version with Lem's `qlfile.lock`, and pin by git wherever Lem needs a newer one.
2. **Register the Lem checkout as a `:tree` in `boot.lisp`.**
   - Lem's mode systems live in subdirectories, such as `extensions/vi-mode/lem-vi-mode.asd`.
   - `boot.lisp` only registers the directory of each lockfile entry's primary `.asd`, so these systems would not be found.
   - Add one `(:tree <lem checkout>)` entry, as `third-party/` already has.
3. **Load a new optional system, `cl-agent/lem`, not the base `cl-agent`.**
   - It depends on `lem/core`, `lem-paredit-mode` (which needs only `lem/core`), `lem-markdown-mode` and the language modes listed in §7.
   - It also depends on `lem-vi-mode` (which also needs lem-lisp-mode, lem-dashboard, esrap and cl-package-locks) and `lem-lisp-mode` (micros, usocket, lem-process with async-process FFI, and lem-lsp-mode).
   - **Do not** depend on `lem`, `lem/extensions`, `lem-fake-interface` (which loads all extensions) or `lem-server`.
   - `make build` builds the `:builtin` image as before. A `make build-lem` target, or a setting checked at start-up, loads `cl-agent/lem`.
4. **Side effects of merely loading Lem.** Accept or undo each of these at load time:
   - It pushes a Lem launcher onto `sb-ext:*ed-functions*` (`src/lem.lisp:145-151`). Remove it, so `(ed)` in the Lisp tab doesn't try to start a Lem frontend.
   - `*git-revision*` runs `git rev-parse` at load (`src/version.lisp:20,27`). This is harmless.
   - It adds `:lem-attached-feature` to `*features*`.
   - Loading `lem-dashboard` (through vi-mode) sets `*splash-function*`. We never call `apply-args`, so this is harmless.

### 4.2 The frontend class: `cl-agent-lem-interface`

This is a subclass of `lem-core:implementation`. It is modelled on `frontends/fake-interface/fake-interface.lisp`, but it is our own class, because the fake one drags in every extension.

- **Implement every generic that has no default** (`src/interface.lisp:82-186`): `invoke`, the foreground and background colour accessors, display width, height and title, fullscreen, the `view` functions, `update-display`, char width and height, `render-line`, `render-line-on-modeline`, `object-width`/`object-height` and `clear-to-end-of-window`.
  - Most of them are no-ops or constants.
  - The display is large, about 200×60, so window-relative commands behave sensibly.
  - Each view records its window, size and position in a struct.
- **`invoke impl fn`** calls `fn` and returns at once. `fn` is our thread starter (§4.3), not Lem's `run-editor-thread`.
- **`update-display` is how state flows back to the page** (§4.6). Lem calls it at the end of every redraw, and redraws when the queue is empty (`src/interp.lisp:72-76`).
- **`render-line`** is a no-op for ordinary windows, since the page renders our buffers itself. For **floating windows**, it keeps the line objects so prompts and pop-ups can be shown (§4.7).
- **`update-cursor-shape`** records the shape vi-mode asks for (`extensions/vi-mode/core.lisp:174-178`), so the page can draw a block cursor in normal state.
- **The `lem-if:set-font*` and `js-eval` generics** keep their no-op defaults. Font settings in a user's init then do nothing instead of failing.

### 4.3 Starting and stopping the editor thread

Write `cl-agent-lem-start`, a copy of `run-editor-thread` (`src/lem.lisp:74-88`) with these differences:

- Call `(lem-core::invoke-frontend fn :implementation (make-instance 'cl-agent-lem-interface))`. This sets `*implementation*` **globally** (`src/interface.lisp:283-286`), which hunchentoot threads need, rather than through `with-implementation`'s dynamic binding.
- **Name the thread `"editor"`.** `send-abort-event` and `find-editor-thread` find it by that name. No cl-agent thread is called that.
- Inside the thread, run what Lem does:
  - `with-editor-stream`, `with-timer-manager (make-instance 'lem-core::lem-timer-manager)` and `setf *in-the-editor*`;
  - `setup`, then `toplevel-command-loop` with **our** init function in place of `(init args)`.
- **Our init function:**
  1. `run-hooks *before-init-hook*`;
  2. `lem-core::load-init-file` (unless the `:lem-no-init` setting is on);
  3. load `(lem-home)/cl-agent.lisp` if it exists (see §4.8);
  4. `run-hooks *after-init-hook*`, which applies the user's colour theme;
  5. create cl-agent's buffers (§4.4).

  It **skips** `apply-args`, so there is no splash screen and no files from the command line.
- **Never call `launch`.** It would reconfigure the host's log4cl root logger and the default external format.
  - Lem still logs through log4cl. Leave log4cl unconfigured, as it is today in cl-agent (nothing in `src/` uses it), or point it at `(config-directory)/lem.log` ourselves.
- **Every call from another thread goes through `lem-call`.** This copies `execute-in-editor` (`extensions/mcp-server/server.lisp:273-297`). It should have a timeout, so a blocked editor thread can't hang an HTTP request, and it should report errors back to the caller.
  - **Never** call `execute-key-sequence` or any command directly from a hunchentoot or agent thread.
- **Stopping:** run `(lem-call (lambda () (exit-editor)))`. This signals `exit-editor`, which `toplevel-command-loop` catches (`src/interp.lisp:140-153`), and the thread then runs `teardown`.
  - `exit-editor` disables every global minor mode first (`src/commands/other.lisp:54-65`).
  - Nothing on this path calls `uiop:quit`. That happens only in the frontends we don't load.
- **Watch the thread.** An error inside Lem's error handler, or during a redraw, calls `bailout` and **ends the editor thread** (`src/interp.lisp:6-35, 75`).
  - The finalize function should mark the Lem engine dead and switch the page back to the built-in editors with a message.
  - Restarting is allowed: `setup`'s once-only code is guarded (`src/lem.lisp:23-34`).

### 4.4 Which buffers back which inputs

| Input | Lem buffer | Mode |
|---|---|---|
| Composer (web, TUI) | `*cl-agent composer*`, temporary (`make-buffer … :temporary t`, `buffer.lisp:150-180`) | `markdown-mode` (prose plus code fences) and `cl-agent-input-mode` |
| Lisp REPL input | `*cl-agent repl*`, temporary | `lisp-mode` (§4.9) and `cl-agent-input-mode` |
| Scratch | the real file, `(config-directory)/repl/scratch.lisp`, through Lem's `find-file` path | `lisp-mode` |

- **`cl-agent-input-mode`** is a minor mode, so its keys take priority even under vi-mode (§3). It binds:
  - **Return → `cl-agent-submit`.** In the composer this submits the buffer text, clears the buffer, and hands the text to cl-agent through the same `frontend-accept-input` path the CLI and TUI use (`src/ui/cli.lisp:28-32`).
    - In the REPL buffer it submits only when the form is complete (the `isComplete` rule from `lisp-editor.js`). Otherwise it calls `newline-and-indent`.
    - Shift-Return, or `C-j`, inserts a newline.
  - **Tab → `cl-agent-complete`.** This asks cl-agent's existing completers (`/api/complete`, or `lisp-repl-complete`, §4.7) with the buffer text and the point's 0-based offset.
  - **`M-p` / `M-n` → history.** cl-agent keeps the history; the command replaces the buffer text.
- **One frame, one ordinary window.**
  - When the page focuses an input, it calls `lem-call (switch-to-buffer <its buffer>)`. Only one cl-agent input has focus at a time, so commands that use `(current-window)` act on the right buffer.
  - Lem resets the current buffer to the current window's buffer after each command (`fix-current-buffer-if-broken`, `src/interp.lisp:66-69`), which suits this design.
- **Agent edits to the scratch buffer.** These come from the `lisp-scratch-write` tool and the versioned saves in `lisp-repl.lisp`. While Lem owns the scratch buffer, they become `lem-call` edits to that buffer, and saving goes through Lem.
  - Keep the existing version and conflict protocol between the page and the server, with Lem's buffer as the source of truth.

### 4.5 Keys from the page into Lem

- When an editor is in Lem mode, `lisp-editor.js`'s `keydown` handler and the composer's prevent the browser default for every key except IME composition.
  - They **send** each key as `{key, ctrl, meta, super, shift}`, the same shape `lem-server` uses (`frontends/server/main.lisp:759-790`), via `POST /api/lem/input` with the `X-CL-Agent` header.
  - Copy lem-server's conversion to `make-key` (`main.lisp:759-790`), including how it handles `Return`/`Tab`/`Escape` and shifted characters.
- **Inserting text** (IME commits, pastes, dead keys) sends `{kind: "string", value}`. The server queues the characters as key events (as lem-server's `input-string` does) or uses a single `insert-string` command. The second keeps undo grouping sane.
- **Order:** the page keeps one outgoing queue per page.
  - It sends the waiting keys as a batch and waits for the response before sending the next batch. Keys typed in the meantime build up.
  - This keeps keys in order without the server having to reorder them, which matters because hunchentoot runs each POST on its own thread.
  - On the server, each batch is one `send-event` per key, so Lem's single queue keeps the order.
- **`C-g`** maps to Lem's `keyboard-quit`. To abort a long command, use `send-abort-event`, as lem-server does for `abort` (`main.lisp:785-863`).
- **Keys cl-agent keeps for itself** stay in the page and never reach Lem:
  - the page's Alt-1…9, Alt-L and Alt-S shortcuts and Ctrl-\;
  - Lisp-tab chords that Lem doesn't know, such as `C-c C-c` (compile form) and `C-x C-e`.

  Each editor's keymap lists these. Alternatively, define them as Lem commands in `cl-agent-input-mode`, so they appear in Lem's help and the user can rebind them. **Prefer the Lem commands.**

### 4.6 State from Lem back to the page

The Lem frontend's `update-display` method builds one update for each mirrored buffer that changed, and **publishes it over the existing event stream** (`web-frontend-publish`, `GET /api/events`) as a `lem` event. Each update holds:

- **`edits`**: `[{at, delete, insert}]`, 0-based, collected since the last update by a per-buffer `after-change-functions` hook, plus a **buffer version**.
  - If the page sees a version gap, it fetches `GET /api/lem/buffer?name=…` for the full text.
  - Full text is fine for the composer and REPL. The scratch buffer can be large, so it needs edits.
- **`point`** and **`mark`/region**, converted from 1-based to 0-based offsets, plus `cursor-shape` (§4.2).
- **`mode-line`**: the major mode name, the vi state (`NORMAL`/`INSERT`/`VISUAL`, from `lem-vi-mode` state), and modified/read-only flags. The page shows these where the echo area or input prompt is today.
- **`message`**: Lem's echo-area text, for "Mark set" or "Undefined key: C-x C-q", shown in our echo area.

The page applies the edits to its textarea, sets the selection from point and mark, and keeps its own syntax highlighting. If two pages are open, they mirror the same state, which matches how cl-agent's web UI already works.

### 4.7 Prompts, pop-ups and completion

- **Lem's prompts are floating windows that run a nested, blocking command loop** (`src/ext/prompt-window.lisp:331-365`). Commands such as `M-x`, isearch, `query-replace` and vi's `:` use them.
  - They work without a display, but they block the editor thread until keys arrive.
  - Since all keys go through the event queue, this is fine: the page keeps sending keys, and the prompt reads them.
- **The page has to show the prompt.** Our frontend creates a view when Lem makes the floating window (`make-view` with a floating window).
  - We publish its buffer's text and point as a `lem-prompt` event, rendered in the page's minibuffer row (the echo area), and close it when the view is deleted.
  - Lem's completion pop-up (`src/ext/popup-menu.lisp:110-214`) is another floating window. Render its lines with cl-agent's `menu.js`, either generically or through Lem's popup-menu generics.
- **Completion inside cl-agent inputs** stays cl-agent's: slash commands, `@paths`, and the SLY-style Lisp completer in `lisp-introspect.lisp`.
  - `cl-agent-complete` computes the result in the editor thread from the buffer text and point, then publishes it, and the page shows `menu.js`.
  - Accepting a candidate is a Lem edit, `lem-call` replacing the range, so undo and vi repeat stay consistent.
- **A later option:** register cl-agent's completers as a Lem completion function, so the user's Lem completion settings and keys (such as `C-n`/`C-p` in Lem's pop-up) apply.

### 4.8 The user's configuration

- **Where it comes from:** use Lem's `lem-home` as it is (§3).
  - Add a cl-agent setting, `:lem-home`, that overrides it by setting `LEM_HOME` before the editor thread starts. `lem-home` reads that variable on every call (`src/config.lisp:3-8`).
- **Loading:** `init.lisp`/`.lemrc` are loaded exactly as Lem loads them (§4.3), in `LEM-USER`, inside Lem's error handler. If the init file fails, Lem shows an `*EDITOR ERROR*` buffer.
  - Our frontend notices this, since the error buffer is switched to, and reports the error in cl-agent's echo area and system log rather than hiding it.
  - Editing still works with whatever loaded before the error.
- **Forms that need a real display**, such as `load-theme`, `set-font` or anything naming `lem-sdl2:` symbols, behave as follows:
  - `set-font` and the like hit our no-op `lem-if` methods, so they do nothing.
  - `load-theme` needs a frame and an implementation (`src/color-theme.lisp:62-115`). Both exist after `setup`, so it works. We can even read the theme's colours (§7.3).
  - **Symbols from packages that aren't loaded** (`lem-sdl2:…`) fail when the file is read. Ask users to guard frontend-specific forms with `#+lem-sdl2` (SDL2 pushes that feature, `frontends/sdl2/sdl2.lisp:13`).
  - cl-agent pushes **`:cl-agent-lem`** onto `*features*` so users can write `#+cl-agent-lem` / `#-cl-agent-lem`.
- **`(lem-home)/cl-agent.lisp`** is an optional file loaded after `init.lisp` (step 3 of the init function), for settings that apply only inside cl-agent. Example: "use vi-mode in the scratch buffer but Emacs keys in the composer" via `cl-agent-input-mode`'s hook.
- **State is shared with the user's real Lem.** cl-agent's embedded Lem writes `config.lisp` and `history/` in the same lem-home, and `(setf config)` **rewrites the whole file**.
  - Sharing history is arguably what "use my Lem setup" means. But if both programs run at once, the last one to save overwrites the other's isearch string or theme choice.
  - **Default: share.** Document the race, and make the `:lem-home` setting the way to separate the two.
- **Extensions from Lem's package manager** (`lem-extension-manager`, `(lem-home)/packages/`) are loaded only if the user's init loads them. Nothing extra is needed: if they're there, they load in our image like any other ASDF system. Remember that they then run inside the agent's image.

### 4.9 lisp-mode and its micros server

- Turning `lisp-mode` on in the REPL and scratch buffers would run `self-connect`. That starts a **micros server**, a swank-like code-execution server with no authentication, on localhost inside cl-agent's own image (`extensions/lisp-mode/lisp-mode.lisp:230-239`).
- **Recommendation:** set `lem-lisp-mode/test-api:*disable-self-connect*` to `t` by default.
  - The REPL buffer and scratch keep lisp-mode's syntax table, indentation, paredit and keymaps.
  - Evaluation, completion, autodoc, describe and `M-.` stay with cl-agent's existing in-image routes (`lisp-routes.lisp`, `lisp-introspect.lisp`), bound as Lem commands in `cl-agent-input-mode`.
- If users want Lem's own REPL commands, a `:lem-lisp-connection :self` setting can allow self-connect. In that case, show the open port in the UI.

### 4.10 Terminal UI

- `src/ui/tui.lisp` already moves input through a channel from tuition's event thread (`tui:run`).
- With `:lem`, the TUI's key handler sends tuition key messages to Lem as events. That is a converter from tuition keys to `make-key`, as for the page.
- The input box is drawn from the composer buffer's text and point, taken from `update-display` and delivered with `tui:send`.
- The plain CLI frontend reads whole lines and stays as it is.

### 4.11 Threads and errors in brief

- **Only the "editor" thread touches Lem state.** Everything else uses `lem-call` (synchronous, with a timeout) or plain `send-event` (fire and forget).
- `update-display` runs in the editor thread. Publishing is safe because `web-frontend-publish` and `tui:send` are already safe to call from any thread.
- The agent's conversation thread never waits on Lem, except when the agent edits the scratch buffer, and that `lem-call` has a timeout.

---

## 5. HTTP and events to add (web)

| Route / event | Purpose |
|---|---|
| `GET /api/lem/state` | Engine status (`:builtin` / `:lem` / failed, and why), plus the buffers with text, point, mark, mode line and cursor shape. Used on page load. |
| `POST /api/lem/input` `{buffer, events:[…]}` | Key and string events, in order (§4.5). Mutating, so it requires `X-CL-Agent`. |
| `POST /api/lem/focus` `{buffer}` | Switch the window to the buffer of the input that has focus. |
| `GET /api/lem/buffer?name=` | The full text, for recovering after a version gap. |
| event `lem` | The per-buffer update from §4.6. |
| event `lem-prompt` / `lem-popup` | Floating-window contents (§4.7). |

---

## 6. Phases

Each phase ends with tests, using the existing test isolation: `CL_AGENT_CONFIG_DIR` points at a temp directory. **`LEM_HOME` must also point into it**, so tests never read or write the user's real lem-home. Add this to `call-with-test-state` alongside the config directory, refusing to run if it resolves inside the user's real lem-home.

1. **Spike: load and start.**
   - Pin Lem, set up the `:tree` and build `cl-agent/lem`.
   - Start the editor thread with `cl-agent-lem-interface`.
   - Via `lem-call`, create a buffer, send `"a" "b" C-a C-k` as key events, and read back the empty buffer and the kill ring.
   - **Pass when:** `make test` passes with `cl-agent/lem` loaded, and log4cl's configuration, `*default-external-format*` and `sb-ext:*ed-functions*` are unchanged after start-up.
2. **Composer on Lem (web).**
   - Add `cl-agent-input-mode`, `/api/lem/*`, the `lem` event and the page's keydown forwarding with edit replay.
   - **Pass when:** Emacs keys (`C-a`, `C-k`, `C-y`, `M-f`, `C-/` undo) edit the composer, and Return submits.
   - **Also check vi:** a `LEM_HOME` whose `init.lisp` contains `(lem-vi-mode:vi-mode)` makes the composer modal (`Esc`, `dw`, `i`), and Return still submits.
3. **REPL input and scratch on Lem.**
   - Add lisp-mode with self-connect off, paredit, cl-agent's evaluation, completion and autodoc as Lem commands, and agent scratch edits through Lem.
4. **Prompts and pop-ups.**
   - **Pass when:** `M-x`, `C-s` isearch, `M-%` and vi `:` work in the echo-area row.
5. **TUI on Lem.**
6. **Syntax highlighting by Lem (§7).** This can come right after phase 1: it needs the engine running, but not input forwarding.

---

## 7. Syntax highlighting of Markdown and code by Lem

The goal is that every code block the model writes, and any Markdown or code shown in the page, is highlighted by **Lem's own mode for that language**. A fence ```` ```c ```` highlights as C, the same as in the user's Lem.

### 7.1 What Lem already provides

- **Language modes.**
  - Each mode has a syntax table. Many attach a TextMate-style grammar as the table's syntax parser: for example, `c-mode` uses `(set-syntax-parser table (make-tmlanguage-c))` (`extensions/c-mode/c-mode.lisp:21-22`).
  - Some also use tree-sitter when its native library is present, and fall back to the syntax table when it isn't (`extensions/tree-sitter/integration.lisp:179-185`).
- **Code fences in markdown-mode.**
  - `markdown-mode`'s scanner reads the fence's info string. It looks up the mode with `lem-markdown-mode/languages:find-mode-by-language-name`: a small table (`common-lisp`, `lisp`, `emacs-lisp`, `shell`, `json`) and otherwise `lem:find-mode`, a case-insensitive match on the mode name (`src/mode.lisp:103-104`).
  - The block is then scanned with that mode's syntax table (`extensions/markdown-mode/syntax-parser.lisp:37-55`). Unknown languages get `document-code-block-attribute`.
- **Modes from file names:** `get-file-mode pathname` (`src/file.lisp:32`), filled in by each mode's `define-file-type`. For example, `("c" "h") c-mode` (`extensions/c-mode/c-mode.lisp:269`).
- **Where the scanner's results end up.**
  - It leaves its result as the `:attribute` text property on ranges of the buffer.
  - `syntax-scan-buffer` (`src/syntax-scanner.lisp:71-74`) scans a whole buffer.
  - `next-single-property-change` / `text-property-at` (`src/buffer/internal/basic.lisp:150, 193`) walk the runs.
  - The attribute names are the standard ones (`src/attribute.lisp:209-240`): `syntax-string`, `-comment`, `-keyword`, `-constant`, `-function-name`, `-variable`, `-type`, `-builtin`, `-warning`, plus `document-*` for Markdown.

### 7.2 The highlighter

Add `lem-highlight (text &key language pathname)` → a list of `(start end attribute-name)` runs. It is called through `lem-call` and does the following:

1. **Pick the mode**, in this order:
   - the fence's language name, through cl-agent's alias table and then `find-mode-by-language-name`;
   - otherwise `get-file-mode` on the pathname (for tool results that show a file);
   - otherwise give up, leaving the text plain, as today.
   - **The alias table** maps common fence names to Lem mode names: `c`, `h` → C; `cpp`/`c++`/`cc` → the C++ mode if one is loaded, otherwise C; `py`/`python`; `js`/`javascript`; `ts`/`typescript`; `sh`/`bash`/`zsh`/`shell` → posix-shell; `rs`/`rust`; `go`; `json`; `yaml`/`yml`; `html`; `css`; `sql`; `lisp`/`cl`/`common-lisp`; `elisp`; `md`/`markdown`.
   - Unknown names fall through to `lem:find-mode`, so a mode the user loads (a Lem extension that defines `zig-mode`, say) works without changes in cl-agent.
2. **Scan the text**:
   - in a **reusable temporary buffer** for each mode (`make-buffer … :temporary t`; erase, then insert);
   - with the mode set (`change-buffer-mode`) and **with the buffer's change hooks off** (`*inhibit-modification-hooks*`), so cl-agent's mirroring (§4.6) ignores it;
   - by calling `syntax-scan-buffer`, then walking the `:attribute` runs.
   - **Markdown:** scan the whole message in `markdown-mode`. Its own fence handling (§7.1) then highlights each block in its language, and the runs cover both prose structure and code.
3. **Cache** by `(mode, hash of the text)` in a size-limited table. Transcript re-renders and session replays then never rescan.

### 7.3 Turning runs into HTML

- **Where to hook in:** `src/ui/web/markdown.lisp` already pulls fenced blocks out before 3BMD runs (`extract-fenced-code-blocks`, `render-fenced-code-blocks`). It produces `<pre><code class="language-…">ESCAPED</code></pre>`.
  - With the Lem engine running, **escape each run's text separately and wrap it** in `<span class="sx-…">`.
  - The surrounding HTML stays the same, so the copy button and language label from `decorateCodeBlocks` (`static/render.js`) keep working.
- **Map attributes to the CSS classes the page already themes** (`app.css:714-722`, light and dark):

  | Lem attribute | Class |
  |---|---|
  | `syntax-keyword` | `sx-keyword` |
  | `syntax-builtin` | `sx-operator` |
  | `syntax-string` | `sx-string` |
  | `syntax-comment` | `sx-comment` |
  | `syntax-constant` | `sx-constant` |
  | `syntax-function-name` | `sx-def` |
  | `syntax-variable` | `sx-special` |
  | `syntax-type` | `sx-type` (new) |
  | `syntax-warning` | `sx-warning` (new) |
  | `document-header1-6` | `sx-heading` (new) |

  With these classes, Lem decides *what* each token is, while the colours still follow cl-agent's light/dark theme.
- **Optional: the user's Lem theme colours.** If the user's init loads a theme, read each attribute's colour with `attribute-foreground-color` (`src/interface.lisp:238`).
  - Send the colours as a per-attribute CSS variable map (`--lem-keyword: #…`) in `/api/state`.
  - A setting, `:highlight-colours :lem`, then makes the page use them.
- **Sanitizer.** `static/render.js`'s `sanitize` currently keeps only `language-…` classes on `CODE`. Allow `SPAN` with classes matching `^sx-[a-z-]+$`, and nothing else.
- **While a reply is streaming:** highlight a block once its closing fence arrives. Until then, show it plain, as now. Re-rendering a finished reply hits the cache.
- **Without the Lem engine** (`:builtin`, or Lem failed to start), nothing changes: plain code blocks.

### 7.4 Highlighting elsewhere in the page

The same `lem-highlight` call can serve:
- **tool-call results that show file contents:** `read_file` output, diffs (via Lem's `patch-mode`) and `grep` hits with a path, using `get-file-mode`;
- **the Sessions tab's transcript preview**, which uses the same Markdown renderer;
- **the composer and scratch editors**, which could take token classes from Lem's runs for their buffer instead of `lisp-editor.js`'s own tokenizer.

  This is the most consistent option, but it costs a highlight request for every change. Start with code blocks, and move editors to it only if it keeps up with typing (§4.6's updates could carry the runs for the changed lines).

### 7.5 Tests

- C, Python and shell fences produce `sx-keyword` / `sx-string` / `sx-comment` spans on the right tokens. Example: in ```` ```c\nint main(void) { return 0; }\n``` ````, `int` and `return` are keywords.
- Unknown languages stay plain, and the HTML still passes the sanitizer.
- A user-supplied mode, a test system that defines a `test-lang-mode` with a syntax table, is used for ```` ```test-lang ````.
- When the engine isn't running, the output matches today's byte for byte.

---

## 8a. Notes from building it

- **§2's option A turned out to be the right core, hosted differently.** Lem's web frontend (lem-server) is reused in-process: cl-agent's `LEM-HOST-DISPLAY` subclasses its `jsonrpc` class, so Lem renders itself. The problems listed in §2 are handled as follows:
  - **One Lem.** There is one editor thread, cl-agent's, so there is no second Lem.
  - **No exit hook.** Nothing calls `uiop:quit`.
  - **No blocking start-up.** The websocket server starts on demand.
  - **Security** (`LEM-DISPLAY-CLACK-HANDLER`):
    - a loopback `Host` only;
    - websocket upgrades only from the Lem page's own origin;
    - only the client's own files (lem-server's `/local/` serves any file on disk).
  - **Focus.** The client no longer re-focuses itself on blur.
- **The minibuffer bridge** answers a command's prompts from the agent's answers. While a command runs from the agent, Lem's three prompt entry points (`%prompt-for-line`, `%prompt-for-character`, `%prompt-for-file`) and `read-key` (once the command's own pending keys are used up) take the next answer. A prompt with no answer left stops the command with what it asked, never blocking the editor thread. This is what made the agent's earlier `M-x mcp-server-start` attempt fail with "recursive use of prompt window".
- **Lem names files by their true name.** Symbolic links are resolved, so `/var/…` becomes `/private/var/…` on macOS. Look buffers up by both the path as given and its true name.

## 8b. Toward a native frontend

The Lem view reuses Lem's own client unchanged except for two small patches. It may eventually be worth writing **cl-agent's own Lem frontend**: a renderer in the page that draws Lem's views with cl-agent's components. The reasons:
- **One display.** lem-server drives a single display, so every page that connects shares it and resizes it, and there is one set of windows. A native frontend could give each editor box (the composer, the REPL input, scratch, a code view) its own Lem frame or window.
- **Embedding.** The iframe draws Lem on a canvas with its own fonts and theme. A native renderer could use cl-agent's palette and type, fit small inputs, and work with the page's accessibility and focus.
- **One connection.** Draw messages could travel over cl-agent's existing event stream and routes, with its CSRF protection, instead of a second server and a websocket.

The protocol to implement is lem-server's: `make-view`/`resize-view`/`move-view`/`put`/`clear-eol`/`clear-eob`/`modeline-put`/`move-cursor` batched as `bulk`, plus `input`, `login` and `redraw` (`frontends/server/main.lisp`). `LEM-HOST-DISPLAY` already produces these messages, so a native client is mostly page-side work.

## 9. The Lem view (implemented)

- **Starting.** `GET /api/lem/display` starts the server and returns the page URL.
- **Visiting files.** `POST /api/lem/visit` shows a file in Lem's window. It's used by the Files pane, the agent's `open-in-editor`, and switching to the Lem view.
- **Running commands.** `POST /api/lem/run` queues a command for the person at the view (the toolbar's Find file and Buffers). It is refused when no view is open, because the command's prompts would then wait forever.
- **Fallback.** The toolbar's Lem | Simple switch changes to cl-agent's lightweight editor (§4.6's text sync), which still edits the same Lem buffers, and back. The current file goes along both ways. The simple editor only ever writes the document it was made for. Before, switching after `C-x b` in Lem could write one file's text, or an empty text, into another's buffer.
- **Following Lem.** After each command (`*post-command-hook*`) and each visit, Lem tells the page (`lem-buffer` event) when the buffer its window shows, or that buffer's modified state, has changed. The editor thread never publishes itself: a page's lock may be held by a thread waiting on Lem. Its events go through a channel to a publisher thread.
- **Sizes.** A hidden iframe measures 0x0. A login or redraw at that size is ignored or given Lem's current size; Lem's windows at width 0 failed every redraw, and the view stayed blank. The page re-measures the frame when its layout changes (a `ResizeObserver`, then a message to the client, then again once views have resized), and on showing the Code tab. A restarted server's display is on a new port, so the frame is rebuilt. Until the client has logged in, the view says "Starting Lem…".
- **Looking like the page.**
  - Colours: the page reads its own theme tokens (`theme.css`, plus any customisations) and posts them to `POST /api/lem/theme`. That builds a Lem colour theme, `cl-agent`, covering the base16 slots, syntax, modeline, region, popups and isearch. It is loaded without saving it to the user's Lem config, and sent again whenever the theme changes.
  - Tab bar: Lem's tab bar is its own HTML with fixed colours, so `lem/tabbar::generate-html` is wrapped to take the theme's colours while `cl-agent` is the theme.
  - Font: the page's font and size are passed in the URL. The served client loads the font before measuring it and draws glyphs at their real width. Before, the cell was the width rounded down and every glyph was squeezed into it.
  - Chrome: mode lines, borders and popups are square and ruled like the page, using colours passed as `--cl-*` variables.
  - A new browser connection marks every window dirty, so Lem's line cache cannot skip drawing it. The tab bar is marked for an update too: it sends its HTML only when marked, so a page that has just connected would show an empty bar.

## 10. Lem commands for the agent (implemented)

`lem-command` runs a command by name, as `M-x` does, or a key sequence.
- It takes a file, a point and an optional region, answers for the command's prompts, a universal argument, and an option to save.
- It reports the changed lines, Lem's messages, the prompts it answered, any answers left unused, and the point.
- `action=search` lists commands with their documentation.
- While the command runs, the buffer is shown in the window the user is looking at, and put back before Lem redraws, so the view doesn't move.
- Changes are published to open pages.

## 11. The copilot (implemented)

`src/copilot.lisp`. It works like Lem's own `copilot-mode`: the suggestion is shown in the buffer, Tab takes it, and other keys leave it. It doesn't reuse that extension, because Lem's version is tied to GitHub Copilot's language server and Lem's LSP client.
- **Requests.** Each one is tool-free and goes to a provider of the copilot's own, made with `provider-for-model`. It uses the session's model unless `copilot-model` names another. The request holds a system prompt, plus the file around the cursor with a `<CURSOR>` marker. The reply is cleaned of thinking, fences, repeated text and repeated indentation.
- **Display.** The suggestion is real text in the buffer, drawn in `copilot-suggestion-attribute`, which the page theme colours. It is inserted under `with-inhibit-undo`, and the modified flag is restored. It is taken out by:
  - the next command (`*pre-command-hook*`);
  - a save (`before-save-hook`);
  - cl-agent reading or changing the buffer (`*lem-before-buffer-access*`, run by `editor-find-buffer` and `lem-buffer-for`).
- **Keys.** `copilot-suggestion-mode`, a minor mode that is on only while a suggestion shows, binds Tab and M-Right. `C-c Tab` is `copilot-complete`.
- **When it asks.** With `copilot-auto` on, a change to the buffer's text starts a timer for `copilot-delay-ms`. A request runs on its own thread. Its answer is shown only if the generation, buffer tick, point and current buffer are all unchanged.
- **The simple editor.** `lisp-editor.js` takes `suggest` and `suggestAuto` options. The suggestion is drawn after the caret in the highlighted copy of the text, and the textarea is untouched until Tab. `POST /api/copilot/suggest` asks the same copilot about the unsaved text.

## 12. Structural edits by syntax tree (implemented)

`src/syntax-tree.lisp`, the `syntax-tree` tool. It uses tree-sitter-cl, the same bindings as Lem's `lem-tree-sitter`. It doesn't use `lem-tree-sitter` itself, because the agent edits by tree rather than highlights.
- **The native side** is built under `config/tree-sitter/` with `cc`:
  - Our own build of tree-sitter-cl's C wrapper. The prebuilt one names a single library version.
  - One added function for field names. tree-sitter-cl's tree-cursor binding passes pointers to the by-value C API, and crashes.
  - Grammars, cloned from upstream at a pinned tag, checked against the pinned commit, and compiled from their generated `parser.c` (`*syntax-grammars*`). There is one build of each, in `tree-sitter/grammars/`.
  - `tree-sitter/sgconfig.yaml` gives ast-grep the grammars it doesn't build in (Common Lisp). The `structural-*` tools run `ast-grep run --config` with it, so nothing builds a second copy.
  - libtree-sitter itself comes from the system.
- **Edits** go through the file's Lem buffer, like `lem-command`'s, and are refused if they add syntax errors.
  - New text is dedented, then indented to the node's column.
  - `delete` and `insert_after` take a following `,` or `;` with the node.
- **Tests** build the JSON grammar offline from `t/fixtures/tree-sitter-json` (upstream source, unchanged). They are skipped where libtree-sitter is missing.
- **Not yet:** using the grammars' `highlights.scm` for Lem's own highlighting via `lem-tree-sitter`.

## 8. Risks and open questions

- **Lem internals.** The plan calls internal functions: `run-editor-thread`'s body, `load-init-file`, `invoke-frontend` and `with-editor-stream`. Pin the commit, and keep each internal call in one file (`src/ui/lem/host.lisp`) so moving to a newer Lem is a single review.
- **Dependency weight and FFI.**
  - lisp-mode pulls in async-process (`libasyncprocess`), and vi-mode pulls in lisp-mode.
  - Check that the macOS (arm64) prebuilt `libasyncprocess` loads in our build.
  - If it doesn't, ship without vi and lisp-mode first: core, paredit and markdown only.
- **The global vi-mode.** vi-mode is a *global* mode (`extensions/vi-mode/core.lisp:80-84`), so it applies to every buffer in the embedded Lem. A per-input choice ("vi in scratch, Emacs keys in the composer") needs a cl-agent wrapper that switches the global mode on focus. Phase 2 should test this.
- **Init-file side effects.** A user's init can start timers or servers, or load extensions with FFI, all inside the agent's image. The `:lem-no-init` setting and the `#+cl-agent-lem` feature give users control. The UI should say which init file was loaded.
- **Latency.** Each key is a localhost POST plus an event back: a few milliseconds, per §4.5. If typing feels slow, the next step is one long-lived streaming POST for input. Don't predict local echo, since that would defeat Lem's keymaps.
- **The `LSP` nickname** from lsp-base. Checked on 2026-10-13: a fully loaded cl-agent image has no `LSP` or `LEM` package, and `cl-lsp` defines only `CL-LSP`. Check again whenever a dependency is added.

---

## 9. Lem files to read first

`src/lem.lisp`, `src/interface.lisp`, `src/interp.lisp`, `src/input.lisp`, `src/event-queue.lisp`, `src/keymap.lisp` (540-660), `src/mode.lisp`, `src/config.lisp`, `src/buffer/internal/buffer-insert.lisp`, `src/syntax-scanner.lisp`, `src/attribute.lisp` (200-300), `frontends/fake-interface/fake-interface.lisp`, `frontends/server/main.lisp` (keys: 759-863; drawing: 142-153), `extensions/mcp-server/server.lisp` (273-297), `extensions/vi-mode/core.lisp` and `tests/utils.lisp`, `extensions/lisp-mode/lisp-mode.lisp` (60-70, 222-246), `extensions/markdown-mode/syntax-parser.lisp` and `languages.lisp`.
