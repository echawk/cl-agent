# Library migration plan

This is the active implementation plan for the Lambda Symbolics libraries
installed in `ocicl.csv`.  Each row names the production seam to migrate and
the duplicate or missing local mechanism it replaces.  “Integrated” means the
library is on an executed application path with tests; declaring an ASDF
dependency alone does not count.

## Completed

| Library | Integrated seam | Result |
|---|---|---|
| `surgeon` | mutation installation/discard | Definition, variable, and method undo capture precedes live evaluation; rollback restores definitions then registry snapshots. |
| `idsmall` | durable task records | New task IDs are short timestamped, collision-checked identifiers. |
| `sexp-config` | `config.lisp` reader | Bounded inert-data grammar replaces direct project-owned `READ` plumbing. |
| `cl-jobpond` | managed shell jobs | A bounded supervisor pool owns shell-job admission, waiting, cancellation delivery, and lifecycle state; the existing EWMA deadline estimate and explicit OS-process kill remain. |
| `cl-exec-sandbox` | shell-tool policy adapter | Sandbox policy construction and execution are exposed as tools; it is the deterministic enforcement boundary replacing the LLM shell inspector. |
| `daphne` | debug-adapter client tools | DAP lifecycle and request tools are available through the normal tool registry. |

## Migration coverage

Every library added for this migration is listed below.  “Installed only” is
intentional debt, not a claim of integration.  Existing project dependencies
such as `cl-mcp`, `cl-lsp`, and `cl-skills` are outside this migration because
they predate the library-adoption effort and already own their respective
surfaces.

The LLM shell-command inspector has been removed from the execution path.  The
sandbox and normal tool hooks are the policy/enforcement boundary.

## Next migrations

### 1. `sbcl-workers` — real concurrent, isolated subagents (in progress)

The first executable seam is now present: `src/workers.lisp` owns a named,
persistent child-SBCL pool.  `run-subagent-worker-evaluation` exposes readable
`:eval` protocol responses and `stop-subagent-worker` delivers cancellation
before process teardown.  The test proves both heap isolation and persistence.

Replace in-image synchronous `run-subagent` execution with a worker manager
and child SBCL processes.  A parent task should submit several independent
worker requests concurrently, retain task/job IDs, stream or poll results, and
cancel an individual worker without sharing the parent image’s mutable session.

- Retire the assumption that `run-subagent` must call `run-agent-turn`
  synchronously in the parent thread.
- Preserve depth limits, model profiles, and read-only tool sets as serialized
  child contracts.
- Use Jobpond for admission/cancellation around worker requests; use Workers
  for the process/image isolation itself.
- Acceptance: two fixture workers overlap in wall-clock time; cancelling one
  leaves the other’s result usable; no child can mutate the parent session.

### 2. `clinker-transcript` — provider-facing transcript projection (in progress)

`src/transcript.lisp` now maps normalized session messages into Clinker items,
uses `reconcile-items` immediately before each provider request, and projects
the verified ordering back to existing provider-neutral message plists. This
prevents malformed tool-call histories from reaching a provider without a
provider-specific rewrite.

Introduce a transcript projection alongside `session-messages`; append
normalized user/assistant/tool items through it and derive provider message
lists at the provider boundary.

- Retire destructive compaction as the sole history representation.
- Use reconciliation before requests and compaction plans to retain unresolved
  tool calls and their outputs.
- Acceptance: interrupted tool calls gain an explicit repair output, provider
  family handoff filters private items, and compaction preserves original
  durable items.

### 3. `sexp-store` — durable event/session/mutation storage

Replace ad hoc JSON snapshot replacement and local atomic helpers where the
data is Lisp-owned with versioned S-expression snapshots and append logs.

- Start with mutation journals, task receipts, and session-event envelopes.
- Retire duplicated temporary-file publication once equivalent Store-backed
  paths are proven.
- Acceptance: torn append tails recover, writes are process-locked, and an
  event log replays a session projection deterministically.

### 4. `sbcl-generations` — checkpoints and recovery boot

Build generation manifests from committed mutation IDs and use the library’s
checkpoint backend for retained compatible images.

- Add checkpoint/list/rollback operations and a `--safe` path that loads no
  private mutations.
- Do not create checkpoints while Jobpond or UI threads make the image
  multi-threaded; coordinate a single-threaded checkpoint window or use the
  library’s restart backend.
- Acceptance: a committed mutation generation can be listed and selected; a
  deliberately broken private extension still permits safe boot.

### 5. `setinka` — typed, observable settings

Layer typed runtime settings over static `config.lisp` defaults.  Begin with
provider/model, UI, compaction threshold, shell timeout, worker concurrency,
and policy mode.

- Retire scattered default validation in session construction after compatible
  settings are exposed.
- Back durable values with the Sexp Store migration.
- Acceptance: changing a session setting validates/coerces, notifies listeners,
  persists when durable, and is visible through one reflection API.

### 6. `lambda-debugger` — conditions and restarts workbench

Wrap extension load, provider requests, worker failures, and mutation exercises
in observable debugger sessions.  Surface detached condition snapshots in all
frontends before allowing a selected restart/recovery.

- Retire plain string-only condition reporting at these boundaries.
- Acceptance: a fixture restart can be inspected and selected without an
  interactive Lisp debugger, and recovery receipts are journaled.

### 7. `clasted` — structural read/rewrite planning

Expose a structural query/rewrite-plan tool backed by immutable source
snapshots.  Start with preview-only plans; publication remains the existing
guarded file-edit path until revision-checked multi-file publication exists.

- Do not require `ast-grep` for the base integration; enable its optional
  backend only when installed/configured.
- Acceptance: a fixture rewrite returns a preview and rejects stale source
  revision or overlapping edits before any file is changed.

### 8. `agentcomms` — ACP server

Add a dedicated ACP entry point that adapts sessions/frontends to an
`agentcomms` agent peer over standard I/O.

- Keep MCP server behavior separate; ACP is editor/client control, not tool
  transport.
- Map ACP cancellation to session/job/worker cancellation and stream frontend
  updates as ACP session updates.
- Acceptance: an in-process ACP client can initialize, create a session,
  submit a prompt, receive streamed text, and cancel a running turn.

## Cross-cutting order

Implement in this order: Workers + Jobpond concurrency, Transcript, Store,
Generations, Settings, Debugger, Clasted, ACP.  Each migration must remove or
isolate the duplicated local path, add focused tests, and update this document
from “next” to “completed.”
