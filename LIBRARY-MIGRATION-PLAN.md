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

`src/tasks.lisp` adds the task runtime on top of it: an inert child contract
(`build-subagent-contract`), a worker-side entry (`run-subagent-worker-task`)
that rebuilds a real provider and a silent session in the child, a task state
machine with Jobpond admission/timeout/cancellation, registered roles, a
grantable-tool allowlist, and `start-subagent`/`wait-subagent`/`cancel-subagent`/
`list-subagents` tools.  Extension points: hooks `:before-subagent-start`,
`:after-subagent-result`, `:subagent-task-transition`; `register-subagent-role`;
`provider-worker-spec`; `*subagent-grantable-tools*`; tasks and roles are
components and emit events.  `run-subagent` (and so `delegate-task` and
`explore-project`) uses workers whenever the provider is rebuildable, falling
back to the in-process path otherwise (`*subagent-execution-mode*`).

Remaining work:

- [ ] Cold start: each child loads cl-agent from source (about 20 s).  Use the
  `sbcl-workers` saved-image support so children boot a prebuilt core.
- [ ] Children lack extension, MCP and LSP tools; missing tools are reported, and
  role `:setup-forms` can load them.  Decide how enabled extensions reach children.
- [ ] Write-enabled children, which need the capability/policy layer and
  worktree isolation from the roadmap (P4, P7).
- [ ] Persist task records so tasks survive a restart; tasks left `:running`
  should become `:unknown` rather than being re-run.
- [ ] Stream child output, not only tool and token progress.
- [ ] Provider requests cannot be aborted mid-flight for providers that do not
  stream; an interrupt lands when the response returns.

Original goal, for reference: replace in-image synchronous `run-subagent` execution with a worker manager
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

### 3. `sexp-store` — durable event/session/mutation storage (in progress)

Debugger receipts and committed mutation journals now use
`sexp-store:snapshot-write` and `snapshot-read` on their production paths.
This replaces their bespoke printer/read plumbing with atomic one-form
publication, evaluation-disabled reads, and rejection of partial or
concatenated snapshots.  Focused tests exercise both paths.

- [x] Migrate mutation journals and debugger receipts to snapshots.
- [ ] Add an append-only, process-locked session-event envelope log and replay
  it into the session projection.
- [ ] Migrate task records/receipts from JSON snapshots to store records and
  logs, including restart recovery for tasks found in `:running` state.
- [ ] Define versioned schemas for persisted records before settings and
  generation manifests consume them.
- Retire duplicated temporary-file publication once equivalent Store-backed
  paths are proven; generic text/source writes remain on the local helper.
- Remaining acceptance: torn event-log tails recover, concurrent writers are
  process-locked, and an event log replays a session projection deterministically.

### 4. `sbcl-generations` — checkpoints and recovery boot (in progress)

`src/generations.lisp` now builds an `sbcl-generations` store over the shared
S-expression persistence layer.  Checkpoints record the committed-mutation
frontier, use the library's verified fork-and-probe backend, and atomically
publish the selected generation pointer only after the core passes its probe.
The agent has `list-generations`, `checkpoint-generation`, and
`rollback-generation` tools.  A checkpoint correctly refuses to fork whenever
the process has more than one live Lisp thread.

- [x] Add checkpoint/list/rollback operations and generation manifests.
- [ ] Add a launcher command that consumes the selected pointer and boots its
  saved core directly; current source-mode startup intentionally does not
  replace its own heap.
- [ ] Add a `--safe` path that loads no private mutations.
- Do not create checkpoints while Jobpond or UI threads make the image
  multi-threaded; coordinate a single-threaded checkpoint window or use the
  library’s restart backend.
- Remaining acceptance: a committed mutation generation can be booted through
  the launcher, and a deliberately broken private extension still permits safe
  boot.

### 5. `setinka` — typed, observable settings (in progress)

`src/settings.lisp` now owns a dedicated Setinka registry and persists its
durable values in a versioned, process-locked `sexp-store` snapshot.  The first
live settings are compaction percentage, tool-call limit, orchestration mode,
and maximum subagent depth.  They are loaded into every session, validate and
coerce textual updates, notify a listener that updates the live session, and
are reflected/edited through `/settings`.  Compatible `config.lisp` values
remain explicit startup overrides.

- [x] Back durable values with Setinka and the Sexp Store transaction layer.
- [x] Move compatible session defaults and validation into typed settings.
- [x] Provide a reflection/update surface with `/settings`.
- [x] Move managed-shell default/deadline bounds, live Jobpond subagent
  concurrency, and sandbox network policy into typed settings.  Shell and
  sandbox settings are resolved from the active session; the shared worker
  pool updates its admission limit atomically.
- [ ] Add typed provider/model and UI settings after provider/frontend discovery
  can supply their dynamic choice lists.
- [ ] Replace remaining direct session field mutation in legacy slash commands
  with setting writes where the setting owns that field.

### 6. `lambda-debugger` — conditions and restarts workbench (first slice done)

Tool execution now runs under `call-with-debugger` (`src/debug.lisp`).  An
unhandled error is selected while its stack is live, journaled as a receipt
under `debugger/receipts/`, and passed through the `:tool-failure` chain hook,
which may choose abort (default), retry, a restart, or replacement values.
The agent can use `list-failures`, `inspect-failure` and `set-failure-recovery`;
subagents journal receipts into the parent's config directory.

Remaining work:

- [ ] Wrap provider requests (retry, use-value and abort restarts around
  `chat-stream` in `run-agent-turn`).
- [ ] Wrap extension load and mutation exercises.
- [ ] Wrap worker failures: `run-subagent-worker-task` still flattens a child
  failure to a string instead of a detached condition snapshot.
- [ ] Surface live conditions and receipts in the frontends (TUI panel, web pane,
  CLI line), alongside the subagent and queue displays.
- [ ] Interactive restart choice by the user or model.  Restarts are only valid
  during the failing call, so this needs the failing call to wait on its own
  thread while a frontend or tool supplies the choice.
- [ ] Optional diagnostic subagent that reads a redacted receipt and recommends
  a recovery (a recommendation, never authority to invoke a restart).
- [x] Journal debugger receipts through `sexp-store` snapshots.

Wrap extension load, provider requests, worker failures, and mutation exercises
in observable debugger sessions.  Surface detached condition snapshots in all
frontends before allowing a selected restart/recovery.

- Retire plain string-only condition reporting at these boundaries.
- Acceptance: a fixture restart can be inspected and selected without an
  interactive Lisp debugger, and recovery receipts are journaled.

### 7. `clasted` — structural read/rewrite planning (in progress)

`src/structural.lisp` now turns an existing file into an immutable Clasted
snapshot with a content digest revision.  Plans produce a full non-writing
preview, reject overlap through Clasted, and can prove stale after the observed
file changes.  `structural-rewrite-plan` lazily enables Clasted's optional
ast-grep backend when `ast-grep` is available, and otherwise fails with an
actionable installation message.  Publication remains the existing guarded
`edit-file` path.

- [x] Do not require `ast-grep` for the base integration; load it only for a
  structural query/rewrite request.
- [x] Reject stale source observations and overlapping preview edits before any
  file is changed.
- [x] Add structural query-only results and a revision-checked multi-file
  publication adapter.  The adapter validates every snapshot before its first
  atomic write; a later filesystem I/O failure remains visibly partial because
  portable cross-file transactions do not exist.

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
