# Feature Proposal: Persistent Agent Memory

## The Problem

Right now, every cl-agent session starts completely cold. When the process restarts, everything the agent learned during the previous conversation is gone — the project's quirks ("tests fail unless you preload the fixtures module"), user preferences ("always use DEFSTAR forms"), confirmed facts ("the API key is in `~/.config/secrets`"), and hard-won lessons ("don't trust the `/models` endpoint; it lists models that 503").

The agent already has three persistence-adjacent mechanisms, but none of them solve this:

| Existing mechanism | Why it falls short |
|---|---|
| `write-extension` | Persists code (new tools, hooks, providers) — not facts. An extension that hardcodes a fact is the wrong abstraction. |
| `write-scratch-file` | Writes to `~/.config/cl-agent/scratch/`, but the files are non-searchable, non-auto-loaded, and unstructured drafts. The agent would have to know a filename exists and cat it. |
| `compact-session-history` | Summarizes prior turns — but only within the current session, and only to save context-window space. It doesn't survive restart. |
| `persist-task-record` / `record-task-tool-evidence` | An audit trail of what the agent did (for stats/accountability), not knowledge it learned. |

There is a real, demonstrable gap: no searchable, structured, cross-session knowledge store. I verified this by searching the live image for `memory`, `cache`, `save`, `persist`, `note`, and `evidence` — nothing provides cross-session knowledge persistence.

## What the Feature Is

A persistent memory system — a durable, searchable knowledge notebook that the agent writes to during conversations and automatically wakes up with at the start of every new session.

It consists of three tools and two hooks, all implementable as a single extension file.

### Tools (from the agent's perspective)

- **`remember`** — "Save this for later." The agent calls it when it discovers something worth keeping across sessions. Parameters: `key` (short title), `body` (the fact/lesson/preference in a sentence or two), `tags` (optional list for categorization), and `scope` (`:global` or `:project`, default `:project`).

  Example: While exploring a project, the agent discovers the test suite requires a specific env var. It calls `remember` with key `"test-env-var"`, body `"Tests fail with 'DATABASE_URL unbound' unless DATABASE_URL=test is set — set it before running make test."`, tag `"testing"`.

- **`recall`** — "What do I know about…?" Searches the memory store by keyword (substring match against key + body) or by tag. Returns matching entries with their IDs, keys, and bodies.

  Example: At the start of a new session in the same project, the agent calls `recall` with query `"test"` and gets back the env-var entry, saving a rediscovery cycle.

- **`forget`** — "This is no longer accurate." Removes an entry by ID. Lets the agent retract outdated knowledge rather than accumulating stale facts.

### Automatic Injection (from the agent's perspective)

The agent doesn't have to call `recall` to benefit. At session start, a knowledge digest — just the keys and one-line summaries, not full bodies — is automatically injected into the first request context. So when a new session begins, the agent effectively "wakes up already knowing" what it remembered, without spending a tool call or burning tokens on full-text retrieval. Full bodies are available on-demand via `recall` when a digest entry is relevant to the current task.

## How It Would Work Internally

### Storage

Files under `~/.config/cl-agent/knowledge/`:

- `global.lisp` — cross-project memories
- `<project-hash>.lisp` — per-project memories, keyed by project root path

Each file holds one readable Lisp plist per memory entry — chosen over JSON so the agent can inspect and debug the store with `eval-lisp` or edit it by hand. An entry's structure would be a plist with keys `:id`, `:key`, `:body`, `:tags`, `:created`, and `:project`.

This mirrors the existing `extensions/` and `scratch/` directory pattern under `~/.config/cl-agent/` — no new infrastructure needed.

### In-memory cache

A variable holding a list of entry plists, loaded at startup, so tool handlers don't re-read from disk on every call. Writes append to both the cache and the file.

### The three tools

Each is defined with `DEFINE-TOOL`, conforming to the real schema verified in the source: the macro signature is `(name (args-var) (&key description parameters) &body body)`, expanding to `(register-tool (make-instance 'tool ...))` with the body wrapped in a handler lambda whose result is coerced to a string. The `TOOL` class has four slots — `name`, `description`, `parameters`, `handler` — each with a reader accessor. Argument validation is handled automatically by `RUN-TOOL-CALL` via `TOOL-CALL-JSON-ERROR` before the handler runs.

So the three tools would each be a `DEFINE-TOOL` form: `remember` builds the entry plist, generates an ID and timestamp, appends to the in-memory cache, and serializes/appends to the appropriate file; `recall` filters the cache by substring match on key+body or tag equality and returns formatted results with IDs; `forget` removes the entry from the cache and rewrites the file without it. All three inherit `HANDLER-CASE` isolation, string-coercion of results, and argument validation from the existing tool infrastructure — they provide only their domain logic.

### The two hooks

Registered via `ADD-HOOK` at extension load time. The exact hook contracts verified from `src/hooks.lisp`:

- **`:on-startup`** — a notify hook (fires once via `RUN-HOOK`, return values ignored, errors caught and reported but non-fatal). It loads the knowledge store from disk into the in-memory cache and prints a brief confirmation. Fired at `repl.lisp` line 1273.

- **`:before-request`** — a chain hook (fires via `RUN-HOOK-CHAIN`, receives one value and must return one value). It receives the plist `(:messages LIST :tools LIST)` about to be sent to the provider. On the first request of a session, it prepends a system-role message containing the knowledge digest (keys + one-line summaries only); subsequent requests pass through unchanged. Registered with `:append nil` so it runs first in the chain. Fired at `repl.lisp` line 894 inside `RUN-AGENT-TURN`.

The digest message would look something like:

```
## Persistent Memory (from prior sessions)
- [test-env-var] Tests fail unless DATABASE_URL=test is set before make test
- [user-prefers-defstar] User wants all function defs to use DEFSTAR forms
- [api-key-location] API key is in ~/.config/secrets, not env vars
Use the `recall` tool to retrieve full details.
```

This costs a modest number of tokens proportional to the number of stored entries — kept small because only keys and summaries are injected, not full bodies.

## Why This Is the Right Feature

- **It fills a verified gap.** I searched the live image for `memory`, `cache`, `save`, `persist`, `note`, and `evidence` — nothing provides cross-session knowledge persistence. The closest mechanisms each serve different purposes and none is a memory store.

- **It directly benefits AI agents.** The agent currently rediscovers project structure, user preferences, and gotchas from scratch every session. Memory eliminates that redundant exploration — fewer tool calls, fewer false starts, faster convergence on the user's actual goal. It's the difference between an amnesiac consultant and one who remembers the codebase.

- **It uses only existing extension points.** Every piece plugs into a verified mechanism: `DEFINE-TOOL` for the tools, `ADD-HOOK` with `:on-startup` (notify) and `:before-request` (chain) for the hooks, the `~/.config/cl-agent/` directory pattern for storage. No core source changes required — it's a pure extension file.

- **It's appropriately scoped.** Project-scoped storage prevents cross-contamination (project A's testing quirks don't clutter project B's context). The `forget` tool handles staleness. The digest-injection approach keeps token overhead low while making memory passive (the agent benefits even if it never calls `recall`).

- **It composes with the existing architecture.** Users who want a more powerful backend (embeddings, vector search, a remote knowledge base) can implement it as an MCP server — the built-in store is the zero-setup default, not a lock-in. The `:after-tool-call` hook could even be used later to auto-suggest memories ("you just hit an error — did you know you remembered a similar one?"), but that's a future enhancement, not part of this proposal.

## Implementation Footprint (Summary)

| Component | Mechanism | Verified API |
|---|---|---|
| 3 tools | `DEFINE-TOOL` macro | `(name (args-var) (&key description parameters) &body body)` → `REGISTER-TOOL` |
| Startup load | `:on-startup` notify hook | `(add-hook :on-startup 'name fn)` → fired by `RUN-HOOK` at `repl.lisp:1273` |
| Digest injection | `:before-request` chain hook | `(add-hook :before-request 'name fn :append nil)` → fired by `RUN-HOOK-CHAIN` at `repl.lisp:894`, receives/returns `(:messages :tools)` |
| Storage | Files under `~/.config/cl-agent/knowledge/` | Mirrors `extensions/` and `scratch/` patterns from `extensions.lisp` |
| Delivery | One file: `~/.config/cl-agent/extensions/memory.lisp` | Auto-loaded by `LOAD-ENABLED-EXTENSIONS` at startup |

---

That's the full proposal — no code was written or evaluated; it's a textual design grounded in the live image's actual APIs and verified extension points.
