# Live sessions: several agents at once in one cl-agent

Several sessions run at the same time in one cl-agent process, each with
its own working directory, model, tools, subagents and conversation. The
web UI shows them as vertical tabs down its left edge. Each tab's label
runs top to bottom, with a dot for busy and a count of unread messages.
Clicking a tab switches to that session. A session keeps working while
you look at another.

## What is per session, and what is shared

| | Per session | Shared by all |
|---|---|---|
| Conversation, durable log, stats | ✓ (`agent-session`, already) | |
| Provider and model | ✓ (`session-provider`, already) | API keys, provider registry |
| Tools offered, capability mode, settings | ✓ (already) | the tool registry, extensions, hooks |
| Subagents, task records | ✓ (keyed by parent session, already) | the worker pool |
| **Working directory** | ✓ (**new**: `session-directory`) | |
| **Environment** (container) | ✓ (per project, follows the directory) | podman |
| **Web state**: transcript, activity, queued input, busy | ✓ (**new**: one `web-session-view` each) | the HTTP server, assets, Lem |
| Memory | per project (follows the directory) | global memories |
| Lem editor | | one editor, many buffers |

## 1. The working directory becomes per session

Today `set-working-directory` calls `uiop:chdir` and sets
`*default-pathname-defaults*`. Both belong to the whole process, and about
20 call sites read `(uiop:getcwd)`. Two sessions in different
repositories would therefore fight over the directory.

- **A slot:** `agent-session` gets a `directory` slot.
- **Per thread:** a session's turn binds `*default-pathname-defaults*` to it
  for that turn's thread, so relative pathnames resolve against it. This is
  a dynamic binding, which is thread-local in SBCL.
- **One accessor:** `(current-directory)` returns the current session's
  directory, or the process's when no session is running. It replaces every
  `uiop:getcwd` in tools, editor, memory, environments, logic, syntax-tree,
  LSP roots and skills.
- **Child processes:** shell jobs are given `:directory` explicitly.
  `uiop:launch-program` passes it to the child, so `chdir` is never needed.
- **Changing it:** `set-working-directory` sets the current session's
  directory and runs `:working-directory-changed` with the session. It
  stops changing the process's own directory, except for the first session,
  so the terminal REPL behaves as before.

## 2. The web UI serves many sessions

- **The registry:** a `live-sessions` registry maps an id to a
  `web-session-view`. The view holds the session, its transcript, activity,
  open tool calls, queued input, busy flag, worker thread and unread count.
  These are the fields `web-frontend` holds today, moved out.
  `web-frontend` keeps the server, connections and the registry.
- **Requests:** every request names its session, with the header
  `X-CL-Agent-Session`, or `?session=` for event streams. A request without
  one goes to the first session, so existing pages and scripts keep working.
  `*web-frontend*` handling stays the same, and a new `*web-view*` is bound
  per request.
- **Live updates:** they carry the session id. The page keeps one stream and
  routes each event to its session's view. Events for a session in the
  background only bump its unread count and busy dot.
- **Session lifetime:**
  - `POST /api/live` creates a session from a directory and an optional
    model and name; it starts idle.
  - `DELETE /api/live?id=` stops a session: it interrupts it, finishes its
    durable log, and frees it. Its history stays in the Sessions tab.
  - Resuming a stored session from the Sessions tab opens it as a new live
    session, unless it's already live, in which case it switches to it.
- **Frontend calls:** the `ui-*` generic functions dispatch on the session's
  frontend, which becomes its view. The turn code and tools are unchanged,
  because they already go through `session-frontend`.

## 3. Turns run on each session's own thread

Each live session gets a worker thread for its turns. Input queued while
the session is busy waits on its own queue, so sessions never block each
other. Turns already bind `*current-session*` per thread. Things that are
global but keyed by session (shell jobs, subagent tasks) are already safe.
Truly global state stays global, guarded where it's mutated:
- the tool registry;
- MCP connections;
- the copilot's buffer state;
- the Lem editor, whose calls are serialised on its own thread.

## 4. The page

- **The tab rail:** a narrow rail on the left. Each tab's name is set with
  `writing-mode: vertical-rl`, so it reads top to bottom. A tab also shows
  a busy dot, an unread count and the project's name. A `+` at the bottom
  opens a small form with a directory (with `find-file` completion), a
  model and a name.
- **Switching:** clicking a tab swaps the active session. The panes (the
  Listener, the Lisp and Code tabs, the side panels) re-render from that
  session's view. There's nothing to reload, since each view's state is
  already in memory on the server.
- **Keys:** `Alt-↑` and `Alt-↓` move between sessions; `Alt-N` starts a
  new one.
- **Labels:** the title bar shows the active session's directory and model.

## 5. Limits and order of work

1. The per-session directory, plus its tests. This is the risky part.
2. The live-session registry and session-aware routes and events. A single
   session works exactly as today.
3. The worker thread for each session.
4. The tab rail and switching in the page.
5. Turning resume into open-as-live: `POST /api/live {resume: id}`, and
   **Open in a tab** in the Sessions view. The manifest records each
   session's working directory, so a session reopens where it worked. A
   log held by a running tab can't be resumed anywhere else.

Out of scope for the first cut: separate API keys per session, and per
session web UI customisations.
