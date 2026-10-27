# Emacs as cl-agent's editor: what is built, and what is next

Status: **implemented, beside Lem.** The Code tab's editor switch is
**Lem | Simple | Emacs**, and so is the Lisp tab's scratch pane. Lem stays
the default. It also keeps the jobs that need it in the image: code
highlighting in the conversation, and the agent's `lem-command`.

Files:
- `src/emacs.lisp`: the daemon's lifetime, the bridge, frames, routes, the
  `emacs-command` tool and the doctor check.
- `src/emacs/cl-agent.el`: everything that runs inside Emacs.
- `static/emacs-view.js`: a frame in a pane.
- `static/code.js`, `static/lisp.js`: the two switches.
- Tests: `t/test-emacs.lisp`.

User-facing notes are in the README, under "Emacs as the editor".

---

## 1. How it fits together

**The daemon.** cl-agent runs an Emacs daemon of its own, as a child
process:

```
emacs --fg-daemon=cl-agent-<pid>-<random> [-Q] --eval '(setq cl-agent-parent-pid <pid>)' -l <config>/emacs/cl-agent.el -f cl-agent-start
```

- It loads the person's init file, as Lem loads its own (`*emacs-load-init*`).
  Tests use `-Q` and a `HOME` of their own (`*emacs-environment*`).
- `cl-agent.el` is read into the image at build time (`*emacs-elisp*`) and
  written to the config directory at start, so the binary is
  self-contained.
- When cl-agent has no locale (started from the Dock), the daemon gets
  `LANG=en_US.UTF-8`.

**Frames.** Each pane shows a frame, `emacsclient -t -s NAME`, running in a
terminal (`src/terminal.lisp`, kind `:editor`, kept out of the Terminal tab).
slt's browser client draws it, as it draws the Terminal tab's shells.
- A frame's role, `code` or `lisp`, is its client's `CL_AGENT_FRAME`.
  Emacs reads it with `(getenv "CL_AGENT_FRAME" frame)`.
- Frames share the daemon's buffers.

**The bridge, both ways.**

| direction | how | carries |
|---|---|---|
| cl-agent → Emacs | `emacsclient --eval` (`emacs-eval`, `emacs-call`, `emacs-call-json`) | visits, buffer text, command runs, the page's light/dark; answers are JSON strings |
| Emacs → cl-agent | one line per event on the daemon's stderr: `\037cl-agent ` and a JSON object (`cl-agent--emit`, `emacs-event`) | `ready`, `shown` (per frame), `buffers`, `saved`, `ask`, `eval`, `scratch-saved` |

Text crosses as ASCII both ways, so no locale can mangle it:
- Emacs writes `\uXXXX` escapes into its JSON (`cl-agent--ascii`).
- cl-agent writes `\uXXXX` / `\U00XXXXXX` escapes into its elisp string
  literals (`elisp-string`).

**Lifetime.**
- **Start:** on first use, when a page shows Emacs or the agent needs it.
- **Normal exit:** `emacs-stop` is on `sb-ext:*exit-hooks*` and sends
  SIGTERM, so Emacs auto-saves. SIGKILL follows if it lingers.
- **cl-agent killed or crashed:** a timer in `cl-agent.el` checks every
  second whether Emacs's parent is still `cl-agent-parent-pid`. If not, it
  calls `kill-emacs`. Measured on a live server, the daemon was gone 1 s
  after `kill -9` of cl-agent.
- **Emacs dies first:** the events thread sees stderr end and marks the
  daemon stopped, with the reason. The panes show a note with **Reopen**,
  and the next use starts it again. Closing a frame (`C-x 5 0`) shows the
  same note, and a reopened frame shows the pane's buffer again
  (`onOpen`).

## 2. Parity with Lem

| Lem feature | in Emacs |
|---|---|
| Files pane, `/edit`, `open-in-editor` visit in the editor | `cl-agent-visit` in the code frame |
| The header and Open list follow the editor | `shown` and `buffers` events (`emacs-buffer`, `emacs-buffers` to pages) |
| `/mx` and its completion | M-x typed into the frame; completion from Emacs's commands while Emacs is the editor (`emacs-is-the-editor-p`) |
| `C-c C-a` asks about the region or form | `cl-agent-ask`, in the global minor mode `cl-agent-mode`, so major modes' own `C-c C-a` (cc-mode's) does not hide it |
| `editor-files` sees unsaved text | Emacs's buffers are listed "in Emacs"; read prefers Emacs's buffer |
| `lem-command` | `emacs-command`: prompts answered from `answers` by advice on the reading functions; an unanswered prompt throws out of the command and reports what it asked |
| Agent writes reload unmodified buffers | the `:file-written` hook calls `cl-agent-file-written`; `global-auto-revert-mode` backs it up |
| Emacs saves reach the rest | `saved` runs `:file-written` with by `"emacs"`, so Lem's copy reloads |
| Lisp scratch in the editor | `cl-agent-scratch-mode`: `C-c C-c` / `C-x C-e` / `C-c C-k` evaluate in cl-agent's image; the buffer saves itself after a pause |
| The page's theme | `frame-background-mode` follows light or dark; the tty colours are the page's palette |

## 3. Next

### 3.1 Copilot-style completion in Emacs (not built yet)

Lem has cl-agent's copilot (`src/copilot.lisp`): after a pause in typing,
the model suggests what comes next, in faint text at the cursor, and Tab
takes it. Emacs can have the same, from the same backend and settings.

**Backend: no change.** `copilot-suggest-text (path before after)` already
makes the suggestion. It is a separate, tool-free request with the
session's model, or `:copilot-model`. The page's Copilot on/off chip and
model choice (`/api/copilot`) would govern Emacs too.

**Emacs side, in `cl-agent.el`:** a minor mode `cl-agent-copilot-mode`,
global, and on when cl-agent's copilot "auto" setting is.
- **Asking.** After an idle pause (`:copilot-delay-ms`, passed in at start
  and on change), emit a `copilot` event. It carries an id, the file path,
  the text before and after point (bounded, as Lem sends it), and the
  buffer's `buffer-chars-modified-tick` and point. `C-c TAB` asks
  explicitly, as `M-x copilot-complete` does in Lem.
- **Answering.** cl-agent handles the event off the events thread (a model
  call takes seconds). It calls `copilot-suggest-text`, then
  `(cl-agent-copilot-show ID TEXT)` over `emacsclient --eval`.
- **Showing.** `cl-agent-copilot-show` drops the answer if the buffer's tick
  or point changed since the request: the answer is stale. Otherwise it
  shows TEXT as an overlay at point, with `after-string` in a faint face.
  The overlay never changes the buffer, so the file, saves and the agent
  never see it. Lem achieves this differently, by inserting the text and
  removing it before any access.
- **Keys, only while a suggestion shows.**
  - Tab accepts the suggestion; M-Right accepts its first line.
  - Any other command dismisses it (`pre-command-hook`).
  - These keys live in a keymap that is active only then (the overlay's
    `keymap` property, or a transient minor mode), so the person's own Tab
    bindings and packages (company, corfu, yasnippet) are untouched
    otherwise.
- **Off switch.** `cl-agent-copilot-mode` can be turned off in the person's
  init file. The page's chip is the usual control.

**Testing notes:**
- With a stub provider (`*copilot-provider*`, as the copilot tests do),
  type in a buffer through `emacs-eval` and wait past the delay. The
  overlay shows the stub's text, and `buffer-string` is unchanged.
- Tab inserts it. A key typed between request and answer drops the answer
  (stale).
- Auto off: no request after a pause; `C-c TAB` still asks.
- Toggling the page's chip turns Emacs's mode on and off.
- Two frames: a suggestion shows only in the buffer and window it was
  asked for.

**Alternative, not chosen:** serve the copilot as an OpenAI-compatible
completion endpoint, and let existing packages (`minuet`, `gptel`) use it
with their own UI. That is less work in elisp, but the page's controls
would not drive it, and it would behave unlike Lem's.

### 3.2 Smaller things noted while building

- **The person's own init file is untested.** Development and tests used
  `-Q`. Start time grows with the init file; one that calls `server-start`
  gets cl-agent's server name, which is harmless. Try it with real configs
  and note conflicts here.
- **Mouse.** Clicks in a frame need `xterm-mouse-mode`, which cl-agent does
  not turn on. Consider turning it on per cl-agent frame (a frame
  parameter, or `server-after-make-frame-hook`) without forcing it on the
  person's other frames.
- **Keys a terminal cannot send.** `C-;`, `C-M-%` and others need the Kitty
  keyboard protocol. slt speaks it; Emacs needs a package (`kkp`).
  Consider loading it when present.
- **Unsaved edits between editors.** Emacs reads files from disk, so edits
  unsaved in Lem or the simple editor are not seen. The page warns when
  switching. Moving the text across (Lem buffer → Emacs buffer, marked
  modified) would remove the warning.
- **Images and variable-pitch text.** A tty frame has neither. A GUI frame
  through a web display backend is out of reach for now. The frame is a
  terminal, and slt's SIXEL and Kitty graphics could show images if Emacs
  emitted them.
