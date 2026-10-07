# cl-agent: an introspectable-agent feature roadmap

Date: 2026-10-07

## Executive recommendation

Do not make the next milestone “more tools” or “more providers.” The repository
already has an unusually broad feature surface for its size. The next milestone
should make that surface coherent and safe to change:

> Every component should be addressable, describable, observable, editable,
> testable, versioned, and reversible through one common control plane.

The best next product slice is therefore a **reflection kernel plus transactional
self-modification**. It should answer, from the REPL, web UI, or an API:

1. What components are active, where did each come from, and what does each
   component affect?
2. What exact context, tools, policy, and state will the next model call see?
3. What changed during this task or live mutation?
4. Did the change pass its exercises?
5. How do I undo it, replay it, or boot without it?

This is the clearest way to differentiate cl-agent from a small Claude Code
clone. Claude Code is a useful model for ergonomics, permissions, session
management, and packaging. Autolith is the closer model for Lisp-native
reflection, durable state, definition-level mutation, generations, and
recovery. cl-agent can be smaller than both while making its mechanics more
legible than either.

## Scope and method

This report is based on:

- all tracked source, test, configuration, and integration files in this repo;
- the recent commit history and the uncommitted design notes already present in
  the working tree (read as context, not modified);
- a local `make test` run;
- current primary documentation for
  [Autolith](https://github.com/lambda-symbolics/autolith), including its
  [architecture](https://github.com/lambda-symbolics/autolith/blob/master/docs/architecture.org)
  and [guide](https://github.com/lambda-symbolics/autolith/blob/master/docs/guide.org);
- current official Claude Code documentation for
  [checkpointing](https://code.claude.com/docs/en/checkpointing),
  [permissions](https://code.claude.com/docs/en/permissions),
  [project memory and rules](https://code.claude.com/docs/en/memory),
  [hooks](https://code.claude.com/docs/en/hooks),
  [subagents](https://code.claude.com/docs/en/sub-agents), and
  [MCP](https://code.claude.com/docs/en/mcp).

The recommendations deliberately favor features that reinforce the stated
goal—an agent whose UI and mechanics can be inspected and changed—rather than
generic feature parity.

The implementation sketches below are intentionally small and architectural.
They show the contracts and migration seams the production code should have;
they are not claimed to be copy-paste-complete patches. In particular, durable
formats need versioning and migration tests, security boundaries need
platform-specific enforcement, and live mutation must treat a clean-process
replay as authoritative because Common Lisp cannot generally undo arbitrary
top-level side effects after evaluating them.

## What the repository already does well

At roughly 6,300 lines of Common Lisp under `src/`, cl-agent already has most
of the *seams* an extensible agent needs:

| Area | Existing implementation | Why it is a good foundation |
|---|---|---|
| Model backends | A CLOS provider protocol plus a registry and normalized messages (`src/providers/`) | Vendor-specific wire behavior stays outside the agent loop. |
| Tools | `tool` objects, JSON Schema, a registry, validation, and a `define-tool` macro (`src/tools.lisp`) | Tools are already data plus behavior, not hard-coded branches. |
| Behavior interception | Named chain and notification hooks (`src/hooks.lisp`) | The major request/tool boundaries are already extensible. |
| Frontends | CLI, TUI, and web frontends behind generic functions (`src/ui/`) | The core is demonstrably not tied to one presentation. |
| Live extension | `eval-lisp`, extension files, runtime loading, enable/disable state (`src/extensions.lisp`, `src/tools/extensions-tool.lisp`) | Live change is a first-class product idea, not a debug accident. |
| Agent loop | Streaming, tool rounds, planning, review, stats, context display, and compaction (`src/repl.lisp`) | The loop has several useful control points and good user feedback. |
| Orchestration | Direct/plan/plan-review modes, tool discovery, completion review, task receipts | Planning and verification are visible rather than hidden prompt tricks. |
| Delegation | Isolated child sessions with model profiles, depth limits, and read-only tool sets | There is a safe substrate for specialized workers. |
| External protocols | MCP client and server, LSP queries, Agent Skills | The repo is already participating in useful ecosystem standards. |
| Lisp-specific quality | ANSI CL lookup, live apropos, Mallet/compiler review | The agent can ground changes in its actual runtime and language. |
| Tests | Broad offline tests across providers, streaming, hooks, extensions, MCP, REPL, and UIs | The project has enough test surface to support deeper mechanics. |

There is also a good product instinct throughout the code: dangerous or costly
mechanisms tend to have a smaller, more specific alternative. Examples include
direct file tools rather than requiring shell reads, scratch files rather than
misusing startup extensions, and metadata-only skill discovery before loading
instructions.

## Where the current architecture stops short of the goal

The repository is *extensible*, but not yet uniformly *introspectable and
changeable*. Each subsystem has its own ad hoc registry and lifecycle:

- tools have rich metadata, but no origin, version, permissions, dependencies,
  health, source location, or owner;
- provider and frontend registries contain only keyword-to-class mappings;
- hooks can list registered names, but not their source, timing, failures,
  ordering rationale, or owning extension;
- slash commands are name/function pairs with no common metadata at all;
- skills have metadata and origin paths, but are outside the other registries;
- MCP-contributed tools lose most MCP result types and their connection is the
  only provenance retained;
- session state, task records, UI activity, and hook execution are separate
  representations rather than projections of one event model.

This produces several concrete gaps.

### Live mutation is not transactional

`write-extension` reviews source, writes over the target file, loads it into
the current image, and only then enables it (`src/tools/extensions-tool.lisp:90-131`).
If loading fails, the already-written file remains. More importantly, `load`
can execute several successful top-level forms before a later form fails, so
the running image may be partially changed even though the tool reports a load
failure.

Reloading has no ownership or unload protocol. Re-registering the same named
tool or hook usually replaces it, but a definition removed from the new source
can remain live as a “ghost.” Methods, globals, helper functions, and other
side effects are not reversed. There is no mutation diff, journal, exercise,
commit/discard boundary, clean-process replay probe, image generation, or
recovery boot path.

That is the largest mismatch with the project’s headline promise. A mutable
agent needs a stronger undo story than an ordinary application.

### Durable task receipts are not durable sessions

The task recorder writes a JSON snapshot containing requests, plan fields,
tool evidence, and status (`src/repl.lisp:497-551`). This is useful, but it is
not the authoritative conversation history:

- `session-messages` lives only in memory;
- there is no `resume`, read-only replay, branch/fork, or crash recovery;
- side completions, hook invocations, tool policy decisions, context changes,
  and mutations are not one ordered event stream;
- repeated writes replace the whole task file and are not atomic;
- tool results are truncated in the record without a content digest or an
  external full-result reference.

Claude Code’s checkpoints are saved with the conversation and can separately
restore code, conversation, or both. Autolith goes further with durable
conversation records and a read-only replay debugger. cl-agent currently has
neither capability.

### Safety review is not an authority boundary

The shell tool executes `/bin/sh -c` with the user’s privileges
(`src/tools/shell.lisp:28-40`). The shell-command inspector explicitly evaluates
relevance and scope, not authorization (`src/repl.lisp:846-941`). File tools can
write any path the process can access. MCP tools and live Lisp evaluation have
no common permission model.

The LLM inspector is a useful reasoning check, but it should sit *inside* a
deterministic policy boundary. Claude Code’s permission rules are enforced by
the client rather than by the model; Autolith uses an OS sandbox with scoped
workspace writes, protected repository metadata, bounded time, and no network
by default. This is one area where copying the principle, not the exact product
surface, would materially improve cl-agent.

### Context is inspectable only in aggregate

`/context` estimates conversation and tool-schema size, and `/compact` can
replace history with a summary. That is a good start. However:

- the system prompt is a single large string in `src/repl.lisp`;
- the effective prompt does not expose provenance by instruction or feature;
- there are no persistent project instructions, path-scoped rules, or
  temporary typed context contributions;
- selected skills are returned as tool text rather than becoming a named,
  inspectable context layer;
- compaction is manual and discards the original in-memory message structure;
- model context-window capacity and exact tokenization are not provider
  capabilities.

The existing `context-compaction-proposal.md` correctly identifies automatic
context management as a real gap. It should be implemented on top of durable
session history so compaction changes the *active projection*, not the only
copy of the conversation.

### The UIs expose activity, not the complete mechanics

The frontend protocol is a strong abstraction, but the browser UI still calls
itself a single-session polling proof of concept with no authentication
(`src/ui/web.lisp:1-29`). It displays chat, activity, and summary stats. It does
not yet expose:

- the effective component graph;
- exact context layers and token cost;
- hook order and per-hook latency;
- tool policy and approval decisions;
- mutation diffs and rollback;
- session replay/branching;
- the parent/child task tree;
- live conditions and available restarts.

The answer is not to hard-code all of that into the web frontend. First create
a UI-neutral state/event/control API; then make every frontend a projection of
it.

### Current baseline health

The local `make test` run completed with **534 checks passed and 3 failures**:

- two shell-tool tests expect older, more specific invalid-command messages;
- the end-to-end self-MCP test fails because the server subprocess exits during
  the initialize handshake.

The working tree also contains stale roadmap text: `todo.txt` still asks for
LSP, Skills, and external MCP work that is already implemented. Before adding
large new mechanics, the project should restore a green baseline and add a
small documentation/capability audit to prevent implemented features from
remaining on the active roadmap.

## The architecture to build toward

The central abstraction should not be “extension file.” It should be a
**component** participating in a **transaction** and emitting **events**.

### 1. Component descriptor

Every tool, hook, provider, frontend, slash command, skill, MCP connection,
subagent role, context contributor, and policy should expose a descriptor with
at least:

```lisp
(:id          "tool:read-file"
 :kind        :tool
 :name        "read-file"
 :origin      (:core "src/tools/file-tool.lisp")
 :source      (:pathname "src/tools/file-tool.lisp" :digest "<sha256>")
 :version     1
 :status      :active
 :enabled-p   t
 :provides    (:filesystem-read)
 :requires    ()
 :effects     (:read-files)
 :config      (:example "value")
 :health      (:status :ok :checked-at 4021361123))
```

The descriptor should be data; behavior remains in functions/classes. This
keeps Lisp’s openness without forcing every component into one inheritance
hierarchy.

Core operations should be consistent across kinds:

- `component.list`
- `component.describe`
- `component.graph`
- `component.source`
- `component.diff`
- `component.validate`
- `component.enable` / `component.disable`
- `component.reload`
- `component.history`

Bind a dynamic `*registration-origin*` while loading core files, extensions,
plugins, and MCP servers. Existing `register-*` functions can then attach
provenance automatically without making extension authors repeat it.

### 2. Event envelope

All meaningful activity should use one typed envelope:

```lisp
(:sequence   1842
 :time       4021361123
 :session-id "session-..."
 :turn-id    "turn-..."
 :parent-id  "tool-call-..."
 :kind       :tool-finished
 :actor      "agent:primary"
 :component  "tool:edit-file"
 :status     :succeeded
 :payload    (:tool-name "edit-file")
 :usage      (:prompt-tokens 0 :completion-tokens 0)
 :redactions ())
```

Provider requests, streamed output, tool calls, hook invocations, policy
decisions, file edits, context contributions, compactions, subagent state,
conditions, and mutations should all emit events. Frontends subscribe to the
events they can render. Durable sessions append them. Replay reads them. Tests
assert them. An extension can observe them without adding yet another special
hook point.

Hooks should remain for interception and policy; the event stream is for
observation. Keeping those roles separate prevents an observer from
accidentally becoming a control-flow dependency.

### 3. Transaction and receipt

Any changeable operation should return a structured receipt describing:

- what was observed;
- what was proposed;
- what authority allowed it;
- what changed;
- how it was verified;
- how to undo it;
- whether the undo is still valid.

For file edits, the existing `expected_text` guard is a good seed. Generalize it
to revision/digest-gated resources and atomic publication. For self-mutation,
capture definition/registry state and publish a durable journal entry. For
settings, record the old value, source layer, new value, validation, and
listener effects.

### 4. Projection

Conversation history, task status, the activity pane, stats, context meters,
mutation history, and audit logs should be projections of the same component
and event data. This avoids maintaining a separate semantics for each UI.

## Prioritized feature recommendations

The order below is implementation order, not just a feature wishlist.

### P0 — Restore a trustworthy baseline

This is a prerequisite rather than a headline feature.

Build:

- fix the three current test failures;
- run offline tests in CI on at least the primary supported SBCL/macOS or Linux
  target;
- add an `atomic-write-file` utility and use it for task records, extension
  enablement, ordinary writes, and future stores;
- add `cl-agent doctor` (or `/doctor`) to validate the config, extension load
  set, LSP commands, MCP declarations, writable state directories, provider
  configuration, and current test/build version;
- generate a capability inventory used by both README documentation and the
  doctor command so feature documentation cannot drift independently.

#### Implementation technique and sample

Start with one low-level durability primitive and one read-only diagnostic
protocol. Every later store, transaction, and settings write should reuse the
same atomic publisher instead of opening destination files with
`:if-exists :supersede`.

```lisp
(defun call-with-atomic-output-file (pathname writer)
  (let* ((target (pathname pathname))
         (temporary (make-pathname
                     :name (format nil ".~a.~a.tmp"
                                   (pathname-name target) (random most-positive-fixnum))
                     :defaults target)))
    (unwind-protect
         (progn
           (ensure-directories-exist target)
           (with-open-file (out temporary :direction :output
                                          :if-does-not-exist :create
                                          :if-exists :error)
             (funcall writer out)
             (finish-output out)
             #+sbcl (sb-posix:fsync (sb-sys:fd-stream-fd out)))
           (uiop:rename-file-overwriting-target temporary target))
      (when (probe-file temporary) (delete-file temporary)))))

(defstruct doctor-check id description function)

(defun run-doctor ()
  (mapcar (lambda (check)
            (handler-case
                (list :id (doctor-check-id check) :status :ok
                      :detail (funcall (doctor-check-function check)))
              (error (condition)
                (list :id (doctor-check-id check) :status :failed
                      :detail (princ-to-string condition)))))
          *doctor-checks*))
```

The production helper should create the temporary file in the destination
directory so the final rename stays on one filesystem. On supported SBCL
platforms it should flush both file data and the parent directory; on other
implementations it can document the weaker guarantee. It should also preserve
the destination's existing mode when replacing a file containing secrets.

#### Exact repository changes

- Add `src/storage.lisp` before `config.lisp` in `cl-agent.asd`. Put atomic
  replace, append-record recovery, content hashing, and directory-sync helpers
  there rather than scattering SBCL conditionals across features.
- Change `persist-task-record`, `write-enabled-config`, `write-extension-file`,
  and the ordinary file-writing tool to call the atomic helper. Preserve the
  existing public functions so extensions do not break.
- Add `src/doctor.lisp`, a `doctor` slash command, and a `--doctor` CLI flag in
  `src/main.lisp`. Checks should return structured plists; the CLI/TUI/web
  renderers should only format them.
- Derive the capability inventory from live registries plus a small build
  manifest. Do not parse README prose as the source of truth.
- Correct the two assertions in `t/test-tools.lisp` or restore the more
  specific shell validation messages, then diagnose the fixture startup in
  `t/fixtures/self-mcp-server.lisp` and make the handshake test print captured
  subprocess stderr on failure.
- Add `t/test-storage.lisp` and `t/test-doctor.lisp` to the test system. Test a
  writer error before rename, replacement of an existing file, malformed
  config, absent external commands, and a doctor run that makes no network
  request.
- Add a CI workflow that runs `make test` from the committed dependency lock
  and uploads the failing test log. Keep live Ollama and external MCP tests in
  separately triggered jobs.

Acceptance criteria:

- a fresh checkout has a green offline suite;
- interrupted durable writes leave either the old complete value or the new
  complete value, never a partial file;
- `/doctor` reports actionable component-specific failures without starting a
  provider request.

Relative effort: small.

### P1 — Unified component registry and reflection API

This is the direct implementation of “every component is introspectable and
changeable.” It is also the dependency that makes later mutation, UI, plugin,
and policy work tractable.

Build:

- introduce component descriptors and stable component IDs;
- adapt the existing tool, hook, provider, frontend, slash-command, skill, MCP,
  and subagent-profile registries without breaking their public functions;
- record origin, source digest/location, ownership, dependencies, effects,
  enablement, config schema, and health;
- add a Lisp API, model-facing read-only tools, and `/components` commands;
- add source lookup using SBCL introspection where available, with portable
  fallbacks to registration-time metadata;
- expose a dependency/provenance graph as JSON and readable S-expressions.

Important design constraint: inspection must not require model inference. A
user should be able to learn why a component is active deterministically.

#### Implementation technique and sample

Use a descriptor table beside the existing registries. The component layer
should describe and index existing objects, not become a new god object that
dispatches every behavior. A dynamic registration context lets current macros
and extension source acquire provenance without changing every call site.

```lisp
(defstruct component-descriptor
  id kind name origin source-digest owner version status enabled-p
  provides requires effects config-schema health metadata)

(defvar *components* (make-hash-table :test #'equal))
(defvar *registration-origin* '(:core "unknown"))
(defvar *registration-owner* "core")

(defun component-id (kind name)
  (format nil "~(~a~):~a" kind (string-downcase (string name))))

(defun publish-component (kind name &rest initargs)
  (let* ((id (component-id kind name))
         (old (gethash id *components*))
         (descriptor (apply #'make-component-descriptor
                            :id id :kind kind :name name
                            :origin *registration-origin*
                            :owner *registration-owner*
                            :version (1+ (or (and old
                                                   (component-descriptor-version old))
                                              0))
                            initargs)))
    (setf (gethash id *components*) descriptor)
    (emit-event (if old :component-replaced :component-registered)
                :component id)
    descriptor))

(defun register-tool (tool)
  ;; Keep the current return value and registry contract.
  (setf (gethash (tool-name tool) *tools*) tool)
  (publish-component :tool (tool-name tool)
                     :effects (tool-declared-effects tool)
                     :metadata (list :object tool))
  tool)
```

Descriptor IDs identify a logical component; immutable event IDs identify a
particular registration. Replacing `tool:read-file` should increment its
descriptor version rather than create a second logical tool. Owners should be
separate IDs such as `core`, `extension:foo`, `plugin:acme/linter`, or
`mcp:filesystem`, allowing one owner to contribute many components.

For source provenance, registration-time metadata is the portable truth.
SBCL's `sb-introspect` can enrich it with definition locations, but source
lookup must still work in a dumped executable where debug/source information
may be incomplete.

#### Exact repository changes

- Add `src/components.lisp` after `conditions.lisp`, and load the minimal event
  API it calls before it. Define descriptor serialization independently from
  CLOS objects so JSON output never attempts to encode functions or classes.
- Extend `tool` with optional `effects`, `owner`, and metadata slots while
  retaining all existing initializer defaults. Extend `define-tool` with
  optional `:effects` and `:requires` clauses.
- Wrap `register-tool`, `add-hook`, `register-provider-class`,
  `register-frontend-class`, `define-slash-command`, skill discovery, and MCP
  connection setup with descriptor publication. The old tables remain the
  behavioral registries during the migration.
- In `load-extension-file`, bind `*registration-origin*` to the canonical
  pathname and content digest and `*registration-owner*` to an extension ID.
  In `connect-mcp-server`, bind them to the MCP connection before remote tools
  are registered. Bind core source origin around each ASDF component load with
  an explicit helper or per-file top-level declaration.
- Add `retire-components-owned-by` and call it from MCP disconnect immediately.
  Do not yet call it before extension reload until P2 can restore the prior set
  on failure.
- Add read-only `list-components`/`describe-component` model tools and
  `/components [KIND|ID]`. Return summaries by default and make source/config
  details opt-in so introspection does not flood model context.
- Add `t/test-components.lisp`. Assert stable IDs, replacement versions,
  origin binding, owner cleanup, serialization without function objects, and
  descriptor coverage for every built-in registry entry.

Acceptance criteria:

- every model-visible tool can be traced to core source, an extension/plugin,
  or a specific MCP connection;
- every active hook shows its order and owner;
- disabling an owner identifies all components it would retire;
- all three frontends can list/describe components through the same API.

Relative effort: medium.

### P2 — Transactional self-modification, exercises, and rollback

#### Implementation status (2026-10-07)

Implemented so far: staged extension proposals, reader/review validation, a
clean-process load probe with an isolated configuration directory, registry
snapshot rollback for failed installs, focused transaction-owned mutation
exercises with durable receipts, explicit install/discard/commit APIs, atomic
source publication, and readable mutation-journal receipts.

Not implemented yet: definition/method/variable capture and rollback,
stale-definition retirement on update, replayed generations, `--safe` recovery
boot, named checkpoints, and generation rollback. Registry rollback must not
be mistaken for undoing arbitrary
top-level side effects; the clean-process probe is the current protection for
the parent image, not an OS sandbox.

This should be the flagship next feature. The desired workflow is:

```text
propose -> inspect diff -> preflight -> install -> exercise -> commit
                                      \-> discard/rollback on failure
```

Build it in two stages.

#### Stage A: definition- and registry-level transactions

- parse actual top-level forms instead of using substring checks such as
  `extension-source-integrates-p`;
- write proposed extension source to a staging path, never over the active file;
- compile and load-probe it in a clean child SBCL process;
- capture affected function, macro, method, variable, hook, tool, provider,
  frontend, command, and context-contributor state before live installation;
- bind an owner/origin during live load so all registrations belong to the
  transaction;
- add explicit `self.diff`, `self.exercise`, `self.commit`, and `self.discard`
  operations;
- atomically publish source and enablement only after the load and required
  exercises succeed;
- on update/unload, retire components the previous version owned so removed
  definitions do not stay live as ghosts;
- persist a readable mutation manifest with source hashes, affected components,
  verification evidence, and undo material.

An exercise is focused evidence, not merely “the file compiled.” Examples:

- invoke a newly registered tool with fixture arguments;
- instantiate a provider/frontend;
- run a hook against a fixture context;
- run selected tests;
- verify that required load-bearing components still exist.

#### Stage B: generations and recovery

- keep a pristine launcher or recovery core independent from user mutations;
- replay committed mutations in a fresh process and probe core invariants;
- retain named compatible generations;
- add `generations`, `checkpoint`, and `rollback` operations;
- when startup fails, boot without private mutations and show the failed
  generation plus a bounded crash capsule.

Autolith’s mutation journal, replay probe, private mutation history, stale
definition detection, retained generations, and pristine recovery image are
the strongest ideas to borrow here. Do not begin with exact heap snapshots;
definition-level journaling plus clean-process replay will deliver most of the
value with less platform complexity.

#### Implementation technique and sample

Treat extension publication as a two-phase transaction. Phase one writes only
to a transaction directory and validates in another SBCL. Phase two installs
into the live image under a registration owner, compares the owned component
set, runs exercises, and only then atomically publishes the source and manifest.

```lisp
(defclass mutation-transaction ()
  ((id :initarg :id :reader mutation-id)
   (owner :initarg :owner :reader mutation-owner)
   (target :initarg :target :reader mutation-target)
   (proposed-source :initarg :proposed-source :reader mutation-proposed-source)
   (staged-source :initarg :staged-source :reader mutation-staged-source)
   (before-components :accessor mutation-before-components)
   (after-components :accessor mutation-after-components)
   (undo-actions :initform nil :accessor mutation-undo-actions)
   (state :initform :proposed :accessor mutation-state)
   (receipts :initform nil :accessor mutation-receipts)))

(defun preflight-mutation (transaction)
  (write-atomic-string (mutation-staged-source transaction)
                       (mutation-proposed-source transaction))
  (let ((receipt (run-clean-image-probe transaction)))
    (unless (eq :passed (getf receipt :status))
      (error 'mutation-preflight-failed :receipt receipt))
    (push receipt (mutation-receipts transaction))
    (setf (mutation-state transaction) :preflighted)
    transaction))

(defun install-mutation (transaction)
  (assert (eq (mutation-state transaction) :preflighted))
  (let ((*registration-origin* (list :mutation (mutation-id transaction)))
        (*registration-owner* (mutation-owner transaction)))
    (capture-owned-component-state transaction)
    (handler-case
        (progn
          (load (mutation-staged-source transaction))
          (retire-stale-owned-components transaction)
          (run-mutation-exercises transaction)
          (setf (mutation-state transaction) :installed))
      (error (condition)
        (rollback-mutation transaction)
        (error condition)))))
```

`capture-owned-component-state` must save the actual prior registry entries,
not just descriptors, so a failed tool/hook/provider/frontend registration can
be put back. Definition capture is implementation-specific: on SBCL, save
`fdefinition`, macro functions, bound values, and methods discovered for named
generic functions. Even that cannot reverse arbitrary I/O, thread creation,
foreign calls, or mutations performed by user code. Therefore:

- the staged clean-process probe is mandatory;
- extensions should be documented as declarative top-level definitions plus
  registrations;
- irreversible top-level effects should require an explicit declared
  capability and make same-image discard unavailable;
- a clean replay of committed manifests is the final verification and recovery
  boundary.

Use an S-expression manifest initially so it can be inspected without an
additional database:

```lisp
(:schema-version 1
 :id "mutation-20261007-0004"
 :owner "extension:my-tools"
 :parent-generation "gen-17"
 :source (:target "my-tools.lisp"
          :before-sha256 "<old-sha256>" :after-sha256 "<new-sha256>")
 :components (:added ("tool:my-tool") :replaced () :retired ())
 :exercises ((:id "tool:my-tool/smoke" :status :passed
              :evidence "<receipt-id>"))
 :state :committed)
```

#### Exact repository changes

- Add `src/mutation/protocol.lisp`, `transaction.lisp`,
  `definitions.lisp`, `probe.lisp`, `exercises.lisp`, `journal.lisp`, and later
  `generations.lisp` as serial ASDF components. The project can stay in the one
  `cl-agent` package; the directory is a responsibility boundary, not a package
  requirement.
- Split `write-extension` in `src/tools/extensions-tool.lisp` into proposal,
  preflight, install, exercise, and commit functions. Keep `write-extension` as
  a compatibility convenience that runs the full transaction and returns its
  receipt. Add lower-level `propose-extension`, `exercise-mutation`,
  `commit-mutation`, and `discard-mutation` tools for interactive control.
- Replace substring-based `extension-source-integrates-p` validation with a
  reader loop using `*read-eval* nil`. Inspect top-level operators and reject
  unreadable/trailing input; never claim this static pass proves safety.
- Add a small probe entry point in `src/main.lisp` or a dedicated script. It
  should launch the same locked system, rebind `*config-directory*` to an
  isolated directory, load prior committed extensions plus the proposal, run
  exercises, emit one machine-readable receipt, and exit.
- Make component ownership from P1 authoritative during install. Snapshot old
  owned registry objects, load new definitions, compute added/replaced/stale
  components, and retire stale entries only after successful load.
- Store staged source under `state/mutations/<id>/`, committed manifests under
  `state/mutation-journal/`, and generations as ordered manifest-ID sets. Write
  a `CURRENT` generation pointer atomically.
- Add `--safe`, `--generation ID`, `/mutations`, `/diff-mutation`, `/discard`,
  `/commit`, `/generations`, and `/rollback-generation`. `--safe` must skip all
  private mutations without reading code from their directories.
- Add fixtures that fail on the first form, fail after registering one tool,
  remove a previously owned tool, redefine a function, and perform an
  undeclared irreversible effect. Test active file hashes and component tables
  before and after every path, plus a subprocess restart/replay test.

Acceptance criteria:

- a failed extension update leaves the active file and running component set
  unchanged;
- a successful update can be discarded in the same process;
- restarting from committed mutations produces the same component inventory;
- a deliberately broken startup extension cannot prevent a pristine rescue
  session;
- the UI can display the exact mutation diff and exercise receipts.

Relative effort: large, but central to the project’s identity.

### P3 — Durable sessions, event replay, branch, and rewind

Turn the current task receipts into an append-only session store.

Build:

- assign stable session, turn, request, tool-call, mutation, and child-task IDs;
- append normalized events before/after important side effects;
- persist provider-facing message items without making them the only record;
- store large/full tool results as content-addressed blobs with bounded previews
  in the event log;
- add `resume`, `replay`, `branch`, `rename`, and `export` operations;
- recover interrupted protocol state: if a durable assistant tool call lacks a
  result after a crash, append an explicit unknown-outcome result before reuse;
- support checkpoints at user-turn boundaries;
- let rewind independently restore the active conversation projection, direct
  file edits, or both;
- preserve original events through compaction and rewind. Summaries should be
  projections/checkpoints, never destructive replacement of history.

Claude Code’s separation of “restore code,” “restore conversation,” and
“restore both” is especially good. Autolith’s read-only replay debugger and
durable recovery of incomplete calls fit cl-agent’s introspection goal even
better.

Track direct `write-file`/`edit-file` changes first. Be explicit that arbitrary
shell side effects are not automatically reversible unless a future sandbox or
filesystem overlay captures them.

#### Implementation technique and sample

Use an append-only event log as the source of truth and rebuild the current
session by projection. A newline-delimited JSON log plus content-addressed blob
directory is sufficient for the first version and keeps recovery inspectable
with ordinary tools. Give every record a schema version, monotonically
increasing sequence within the session, and globally unique event ID.

```lisp
(defstruct session-event
  schema-version id sequence time session-id turn-id parent-id
  kind actor component status payload usage redactions)

(defun record-session-event (session kind &key parent-id component status payload)
  (bt:with-lock-held ((session-event-lock session))
    (let ((event (make-session-event
                  :schema-version 1
                  :id (new-id "event")
                  :sequence (incf (session-event-sequence session))
                  :time (get-universal-time)
                  :session-id (session-id session)
                  :turn-id (session-current-turn-id session)
                  :parent-id parent-id :kind kind :actor "agent:primary"
                  :component component :status status :payload payload)))
      ;; Append and flush before publishing to in-memory/UI subscribers.
      (append-json-record (session-event-path session)
                          (session-event->json event))
      (publish-event event)
      event)))

(defun project-conversation (events &optional through-sequence)
  (loop with messages = nil
        for event in events
        while (or (null through-sequence)
                  (<= (session-event-sequence event) through-sequence))
        do (case (session-event-kind event)
             (:user-message-accepted
              (setf messages (append messages
                                     (list (getf (session-event-payload event)
                                                 :provider-message)))))
             (:assistant-response-finished
              (setf messages (append messages
                                     (list (getf (session-event-payload event)
                                                 :provider-message)))))
             (:tool-result-recorded
              (setf messages (append messages
                                     (list (getf (session-event-payload event)
                                                 :provider-message)))))
             (:context-checkpoint
              (setf messages (checkpoint-messages event))))
        finally (return messages)))
```

Side effects need intent and outcome records. Append `:tool-call-started`
*before* dispatch and `:tool-call-finished` afterward. On recovery, an unmatched
start is not automatically a failure: its external outcome is unknown. Append
an `:unknown-outcome` reconciliation event and require user/model review before
retrying non-idempotent operations.

Store large values by digest:

```lisp
(:preview "first bounded characters..."
 :blob (:algorithm "sha256" :digest "<sha256>" :media-type "text/plain"
        :bytes 48193))
```

The blob file should be written atomically before the event referencing it.
Startup recovery may truncate only an invalid final NDJSON line; corruption in
the middle of a log must fail closed and be reported by `/doctor`.

#### Exact repository changes

- Add `src/events.lisp` for the in-process typed publisher and
  `src/store/{ids,events,blobs,sessions}.lisp` for durable storage. Keep
  serialization functions explicit; do not serialize arbitrary Lisp objects.
- Add `id`, current turn ID, event sequence, store path, event lock, and active
  projection/checkpoint slots to `agent-session`. `make-session` should create
  or open a session record before accepting input.
- Instrument `session-submit-user-text`, `run-agent-turn`, `run-tool-call`, hook
  dispatch, context compaction, policy decisions, mutation calls, and subagent
  lifecycle. Each nested operation receives its parent's event ID.
- Change `session-messages` from authoritative mutable history to a cached
  projection. During migration, update the cache after each durable append so
  provider code does not need to change immediately.
- Replace whole-file task JSON rewrites with task projections over events.
  Continue exporting the old JSON shape for compatibility, but label it as a
  generated view and include trace/session IDs.
- Add a file-edit receipt around `write-file` and `edit-file`: before digest,
  after digest, bounded before/after blobs, path relative to the authorized
  root, and an undo precondition requiring the current digest to equal the
  recorded after digest.
- Add `list-sessions`, `resume-session`, `replay-session`, `branch-session`,
  `export-session`, and `rewind-session` APIs plus slash commands. Branches
  record parent session/checkpoint IDs rather than copying provenance away.
- At startup, scan open sessions for incomplete operations and append explicit
  recovery events. Never silently regenerate a missing tool result, because
  the original call might have succeeded externally.
- Add crash fixtures that terminate after intent append, during blob write,
  after file write, and during final event append. Test replay determinism,
  trailing-record repair, middle-log corruption detection, branch lineage, and
  digest-gated rewind.

Acceptance criteria:

- kill the process mid-turn, restart, and resume without corrupting provider
  protocol history;
- replay can step through planner, model, hook, tool, reviewer, and mutation
  events without executing them;
- branch creates a new session lineage while keeping the original readable;
- rewind never overwrites an externally modified file without a revision check.

Relative effort: large.

### P4 — Deterministic capabilities, approvals, and an OS sandbox

Add a real authority layer below the agent’s reasoning checks.

Build:

- annotate each tool/component with effect capabilities such as
  `:read-workspace`, `:write-workspace`, `:process`, `:network`,
  `:credentials`, `:external-side-effect`, and `:self-modify`;
- define modes such as `:inspect`, `:plan`, `:ask`, `:accept-edits`, and
  `:full`;
- support deterministic deny, ask, and allow rules with deny precedence;
- scope file authority to workspace/additional roots and protect `.git`, agent
  configuration, credentials, and mutation history separately;
- route unresolved decisions through a frontend-neutral approval request with
  approve-once, approve-session, deny, and deny-with-feedback outcomes;
- place shell processes in an OS sandbox where supported, with bounded time,
  output, writable paths, environment, and network;
- apply policy to MCP and subagent tools, not only shell;
- retain the current shell inspector as a *relevance* reviewer after policy has
  established that the call is authorized.

The component descriptor’s `:effects` and the event journal’s policy receipts
make the permission system inspectable instead of a hidden set of conditionals.

#### Implementation technique and sample

Separate four concepts: declared component effects, a concrete request,
deterministic rule evaluation, and an optional human approval. Model review is
neither a rule nor an approval. The final decision must be made locally and
record the exact rule that matched.

```lisp
(defstruct capability-request
  session-id actor component operation capabilities resources arguments)

(defstruct policy-rule
  id effect actor component operation capability resource-pattern)

(defun decide-capability (policy request)
  (let* ((matches (remove-if-not
                   (lambda (rule) (rule-matches-request-p rule request))
                   (policy-rules policy)))
         (deny (find :deny matches :key #'policy-rule-effect))
         (ask (find :ask matches :key #'policy-rule-effect))
         (allow (find :allow matches :key #'policy-rule-effect)))
    (cond (deny (values :deny (policy-rule-id deny)))
          (ask (values :ask (policy-rule-id ask)))
          (allow (values :allow (policy-rule-id allow)))
          (t (values (policy-default-effect policy) :default)))))

(defun authorize-tool-call (session tool arguments)
  (let ((request (tool-capability-request session tool arguments)))
    (multiple-value-bind (decision rule-id)
        (decide-capability (session-policy session) request)
      (record-policy-decision session request decision rule-id)
      (ecase decision
        (:allow t)
        (:deny (error 'capability-denied :request request :rule-id rule-id))
        (:ask (request-frontend-approval session request rule-id))))))
```

Arguments must be canonicalized into resources before matching rules. For
example, file paths should become canonical paths under a known root before a
glob is evaluated; shell commands should become a process request containing
executable, arguments, working directory, environment keys, network need, and
writable roots. Rules over the raw command string are too easy to bypass.

Use a backend protocol for process isolation:

```lisp
(defgeneric run-sandboxed-process (backend request))
(defmethod run-sandboxed-process ((backend no-sandbox-backend) request)
  (unless (capability-request-explicitly-allows-unsandboxed-p request)
    (error 'sandbox-unavailable))
  (run-process-request request))
```

Implement a `bubblewrap` backend on Linux and a deliberately scoped platform
adapter on macOS. If the configured restrictions cannot be enforced, fail
closed or ask for an explicit unsandboxed exception; do not quietly fall back.
Credentials should be passed as an allowlisted environment built from scratch,
not inherited and then partially deleted.

#### Exact repository changes

- Add `src/policy/{capabilities,rules,approvals,sandbox}.lisp` and condition
  types for denied, approval-required, approval-expired, and
  sandbox-unavailable outcomes.
- Add `effects` metadata to every built-in tool. Start conservatively:
  `read-file` is `:read-workspace`, file edits are `:write-workspace`, shell is
  at least `:process` plus argument-derived file/network effects, MCP is
  `:external-side-effect` unless the remote declaration is more specific, and
  extension operations are `:self-modify`.
- Add policy/mode slots to `agent-session`. Construct the effective policy in
  `make-session` from defaults, user config, project config, role restrictions,
  and temporary approvals. Child policy must be the intersection of parent
  authority and role policy.
- Call `authorize-tool-call` at the top of `run-tool-call`, before
  `:before-tool-call` hooks or any model-based shell inspection. Hooks may
  narrow or reject an authorized call but may never widen its capabilities.
- Add a frontend-neutral `ui-request-approval` generic returning a structured
  decision. CLI asks synchronously; TUI/web may enqueue and wait with timeout.
  Persist approval request/response events before continuing.
- Refactor `src/tools/shell.lisp` to accept a structured process request and
  dispatch through the sandbox backend. Add strict timeout/output limits and a
  minimal environment. Keep `/bin/sh -c` only as an explicitly classified
  compatibility operation.
- Resolve file-tool paths against configured workspace/additional roots and
  protect `.git`, the configuration directory, credentials, session store, and
  mutation journal with distinct capabilities.
- Put MCP calls through the same policy path and associate their component
  descriptors with connection trust metadata. Unknown remote effects should
  not default to harmless.
- Add policy tests for deny precedence, canonical-path traversal and symlinks,
  approval scope/expiry, child authority intersection, missing sandbox
  backends, environment leakage, MCP calls, and event receipts. Add platform
  integration tests separately from deterministic rule tests.

Acceptance criteria:

- the model cannot bypass a deny rule with prompt wording;
- plan/inspect mode exposes no mutating tools or deterministically rejects their
  use;
- a child role cannot exceed its parent’s capabilities;
- every allow/deny/approval result appears in replay with its matching rule;
- secrets are not inherited by ordinary shell jobs.

Relative effort: large, but it should precede write-enabled concurrent agents
or remote access.

### P5 — First-class context assembly, rules, memory, and automatic compaction

Replace the monolithic prompt plus message list with named context layers.

Build:

- separate invariant core instructions from user, project, directory, role,
  skill, temporary contribution, and policy layers;
- support `AGENTS.md`/project instructions and path-scoped rules that load only
  when relevant files are observed or edited;
- represent context contributions with ID, origin, priority, lifetime
  (`:request`, `:turn`, `:session`, `:workspace`), token cost, and conflict or
  supersession rules;
- show the exact assembled context and why each item loaded;
- add workspace/global memory with source, confidence, last-confirmed time,
  replacement history, and explicit forget/tombstone operations;
- extend providers with context-window/tokenizer/capability metadata;
- implement automatic threshold-based compaction using the existing proposal,
  preserving recent structured messages and writing a durable checkpoint;
- add pre/post-compaction events so extensions can preserve or reinject
  information deliberately.

Claude Code’s split between always-loaded project instructions, path-scoped
rules, on-demand skills, and non-enforcing memory is a useful mental model.
Autolith’s typed context contributors are an even better fit for making the
effective request inspectable.

#### Implementation technique and sample

Make context an ordered collection of contributions, then compile it into the
provider's normalized messages and tools immediately before a request. Each
contribution retains identity and provenance even if several are rendered into
one wire-level system message.

```lisp
(defstruct context-contribution
  id kind origin priority lifetime applies-p render token-estimator
  supersedes sensitive-p metadata)

(defun assemble-context (session request)
  (let* ((candidates (append (core-context-contributions)
                             (session-context-contributions session)
                             (project-context-contributions session)))
         (applicable (remove-if-not
                      (lambda (item)
                        (funcall (context-contribution-applies-p item)
                                 session request))
                      candidates))
         (resolved (resolve-context-conflicts applicable))
         (ordered (stable-sort resolved #'<
                               :key #'context-contribution-priority)))
    (make-context-projection
     :contributions ordered
     :messages (render-context-messages ordered session)
     :tools (effective-context-tools session request)
     :costs (mapcar (lambda (item)
                      (cons (context-contribution-id item)
                            (estimate-contribution-tokens item session)))
                    ordered))))
```

Path rules should use an explicit observed-file set, updated by file/LSP/tool
events. A rule is active when one of its canonical workspace-relative patterns
matches an observed file for the current turn. Merely listing every project
rule in a system prompt defeats the context-saving goal.

Compaction should create a checkpoint contribution rather than mutate the
durable history:

```lisp
(:kind :context-checkpoint
 :covers-through 1842
 :summary-blob "sha256:<digest>"
 :preserved-message-ids ("message-1839" "message-1840")
 :generator (:provider "example" :model "example-model" :prompt-version 2))
```

The next projection selects the checkpoint plus uncovered events. Replay can
still select the uncompressed events. Trigger automatic compaction at a
provider-advertised threshold, with a reserved completion/tool margin and a
hard failure if the minimal projection still exceeds capacity.

#### Exact repository changes

- Add `src/context/{contributions,rules,memory,budget,compaction}.lisp` and move
  `approximate-token-count`, `message-context-characters`, context reporting,
  transcript construction, and compaction out of `src/repl.lisp` behind this
  API.
- Replace construction of one concatenated system prompt in `make-session`
  with core, configured-system, role, project-rule, skill, memory, and temporary
  contribution objects. Preserve the same provider-facing text initially to
  reduce behavioral drift.
- Add provider generics such as `provider-context-window`,
  `provider-count-tokens`, and `provider-reserved-output-tokens`. Implement
  exact counting where an available tokenizer makes it reliable; otherwise
  return an explicitly labeled estimate.
- Discover `AGENTS.md` from workspace ancestors and `.cl-agent/rules/*.md`
  with inert front matter containing path patterns and priority. Record file
  digest and load reason in the contribution. Define precedence rather than
  depending accidentally on filesystem traversal order.
- Change `read-skill` so selected instructions become a session/turn context
  contribution with the skill's path and digest; retain its current textual
  tool result as a compatibility message until provider projections no longer
  depend on it.
- Add a data-only memory store with IDs, origin, confidence, timestamps, and
  supersession/tombstones. Memory contributes suggestions, never policy.
- Reimplement `/context` over a `context-projection`: show ID, origin, active
  reason, priority, lifetime, tokens, conflicts, and redaction status. Add
  `/context show ID`, `/rules`, `/memory`, and explicit forget operations.
- Change `/compact` and automatic compaction to append checkpoint events from
  P3. Add before/after hook or event contracts only after their data shape is
  stable; do not let hooks delete durable history.
- Add tests for rule precedence, path activation/deactivation, skill
  provenance, memory tombstones, exact versus estimated counts, compaction
  thresholds, reserved capacity, checkpoint replay, and an oversized minimal
  context.

Acceptance criteria:

- `/context` can attribute tokens to individual layers/components;
- a user can answer “why is this instruction present?” without reading source;
- compaction never destroys the original session record;
- a rule scoped to `src/api/**` does not consume context for unrelated work;
- memory is editable and forgettable, with provenance visible.

Relative effort: medium to large.

### P6 — An introspection workbench in the web UI

Once components and events exist, turn the web frontend into a mechanics
workbench. Keep chat as one pane; add views driven only by the common APIs:

- **Timeline:** ordered model, hook, policy, tool, subagent, compaction, and
  mutation events with expandable inputs/outputs and duration;
- **Context lab:** layer list, provenance, token cost, enabled tools, and the
  exact next-request projection;
- **Component graph:** providers, tools, hooks, skills, MCP, roles, and owners,
  with source and health;
- **Mutation studio:** staged source, definition/component diff, exercises,
  commit/discard, and generation rollback;
- **Policy panel:** effective capability mode, matching rules, pending
  approvals, and recent denials;
- **Task tree:** primary session plus child tasks, status, budget, model,
  capabilities, outputs, cancellation, and lineage;
- **Session browser:** resume, replay, branch, export, and rewind;
- **Condition inspector:** structured condition, stack snapshot, and restarts.

Move the web transport from polling toward SSE or WebSocket events and support
multiple sessions, but do that as a transport improvement after the event
model. The TUI can expose smaller versions of the same views; it should not
need parallel business logic.

#### Implementation technique and sample

Make the browser a client of read/query/command APIs, not a fourth place where
agent state is computed. A small server-side projection layer can expose stable
view models while the underlying event and component schemas continue to
evolve.

```lisp
(defgeneric query-view (view-name &key session-id parameters))
(defgeneric submit-command (command-name arguments &key session-id actor))

(defmethod query-view ((view-name (eql :timeline))
                       &key session-id parameters)
  (timeline-view (read-session-events session-id
                                      :after (getf parameters :after)
                                      :limit (or (getf parameters :limit) 200))))

(defmethod submit-command ((command-name (eql :mutation-commit)) arguments
                           &key session-id actor)
  (authorize-control-command actor session-id command-name arguments)
  (commit-mutation (getf arguments :mutation-id)))
```

Suggested first HTTP surface:

```text
GET  /api/sessions
GET  /api/sessions/:id/timeline?after=1842
GET  /api/sessions/:id/events                 # SSE resume via Last-Event-ID
GET  /api/sessions/:id/context
GET  /api/components/:id
POST /api/sessions/:id/commands               # typed command + expected revision
POST /api/approvals/:id/decision
```

All mutating commands should include an expected revision/generation and flow
through P4 policy plus P3 event recording. The endpoint must return conflict
rather than applying an edit to stale UI state. SSE is enough for ordered
one-way event delivery; retain ordinary POST requests for commands and add a
WebSocket only if later bidirectional streaming actually needs one.

#### Exact repository changes

- Split `src/ui/web.lisp` into `src/ui/web/{frontend,server,api,views}.lisp` and
  static JS/CSS assets. The current embedded page can remain a build fallback,
  but stop coupling markup edits to Lisp request handlers.
- Introduce a session manager indexed by session ID before enabling multiple
  tabs/sessions. `*web-frontend*` cannot remain the authoritative singleton.
- Add serialization functions for timeline, context, component graph,
  mutation, policy, task tree, and condition views. These functions consume
  core projections and must have no Hunchentoot dependency.
- Add an SSE broker that subscribes to the typed event bus, maintains a bounded
  per-client queue, honors `Last-Event-ID`, and falls back to durable store
  catch-up after reconnect. Emit redacted view events, not raw internal
  payloads containing secrets.
- Replace the existing polling/status signature logic incrementally: first
  stream the same message/activity events, then add route-driven panes for the
  new views.
- Route every UI action through a command registry shared with slash commands
  where semantics match. A `/commit` command and a web Commit button should
  invoke the same command function and produce the same receipt.
- Bind to loopback by default, generate an authentication token, use
  same-origin/CSRF protection for commands, and refuse non-loopback binding
  without explicit auth/TLS configuration.
- Add API contract tests without a browser, then browser tests for reconnect,
  stale-revision conflict, approval completion, redaction, multiple sessions,
  and replay navigation. Keep rendering snapshot tests small and focused on
  view models rather than the full HTML string.

Acceptance criteria:

- the browser can explain every visible activity item by opening its durable
  event;
- changing an allowed setting uses the same transaction API as the REPL;
- no frontend directly mutates core registries;
- reconnecting does not lose the session timeline.

Relative effort: medium after P1/P3, expensive before them.

### P7 — Declarative agent roles and a real task runtime

The current subagent mechanism is intentionally bounded and synchronous. Keep
that safety, but move roles from hard-coded tool wrappers into data.

Build:

- project and user role definitions containing name, routing description,
  system instructions, tool/capability allowlist, allowed child roles, model,
  effort, iteration/runtime budget, blocking/background behavior, and output
  contract;
- durable child-task state and event lineage;
- cancellation, steering, waiting, and structured final yields;
- independent batches with a concurrency limit;
- read-only workers by default;
- worktree isolation for write-enabled coding workers;
- explicit merge/apply review rather than concurrent edits to the main tree;
- a scheduler only after tasks, receipts, and authority are durable.

This turns `delegate-task` and `explore-project` into presets over one runtime
rather than separate long-lived product concepts. The planner can recommend
roles, but recommendation and execution should remain separate events.

#### Implementation technique and sample

Model roles as inert configuration and tasks as a durable state machine. The
scheduler may execute tasks concurrently, but it should not own their semantic
state; every transition must first be validated and appended to the session
event store.

```lisp
(defstruct agent-role
  id description system-contributions model effort capabilities tools
  allowed-child-roles max-depth max-runtime max-tool-iterations
  workspace-mode output-schema)

(defparameter *task-transitions*
  '((:queued . (:running :cancelled))
    (:running . (:waiting :succeeded :failed :cancelled :unknown))
    (:waiting . (:running :cancelled))
    (:unknown . (:running :failed :cancelled))))

(defun transition-task (task next &key receipt)
  (unless (member next (cdr (assoc (task-state task) *task-transitions*)))
    (error 'invalid-task-transition :from (task-state task) :to next))
  (append-task-event task :task-transitioned
                     (list :from (task-state task) :to next :receipt receipt))
  (setf (task-state task) next))

(defun effective-child-authority (parent role)
  (capability-intersection (session-capabilities parent)
                           (agent-role-capabilities role)))
```

The role output contract should be validated before it is delivered to the
parent. The parent receives a bounded summary and trace/artifact references,
not the child's entire prompt history. For write-enabled work, allocate a Git
worktree at a recorded base commit, require a clean patch/result receipt, and
make applying that patch a separate authorized parent operation.

Use a fixed-size `bordeaux-threads` worker pool with a durable queue. A running
task owns cancellation tokens for provider requests and subprocesses. On
restart, tasks left in `:running` become `:unknown` until their owned processes
are proven dead or reconciled; they must not be blindly launched twice.

#### Exact repository changes

- Add `src/tasks/{roles,task,state-machine,scheduler,workspace}.lisp`. Register
  roles and tasks as components so their source, authority, health, and lineage
  are visible.
- Move profile normalization and `run-subagent` out of `src/repl.lisp`.
  Translate existing `:subagent-model-profiles` into implicit roles during a
  compatibility period; `delegate-task` and `explore-project` become thin
  calls to `start-task` with different default roles.
- Define data-only role files under `.cl-agent/roles/` and the user config
  directory. Validate fields, capability names, tool references, output JSON
  Schema, and allowed-child graph cycles before registering them.
- Give every child a session ID linked to parent task/session/turn IDs. Record
  queued, started, waiting, steered, cancelled, output-validated, and terminal
  events in the P3 store.
- Add provider cancellation to the provider protocol and process cancellation
  to the execution layer. Cancellation must be idempotent and have a timeout
  after which the outcome becomes `:unknown`.
- Implement the scheduler with an explicit concurrency limit and per-role
  budget. The scheduler dispatches only after P4 authority is materialized; it
  never asks the model whether the child is allowed.
- Add a worktree manager that records repo root, base commit, branch/worktree
  path, owner task, and cleanup state. Validate that a write role has an
  isolated worktree; never give two running tasks the same writable root.
- Add `list-tasks`, `describe-task`, `start-task`, `wait-task`, `steer-task`,
  and `cancel-task`, plus `/tasks` and task-tree views. The planner may emit a
  role recommendation, but an explicit scheduler/tool action starts it.
- Test invalid transitions, authority inheritance, output-schema rejection,
  concurrency limits, cancellation, restart reconciliation, recursive depth,
  separate worktrees, and parent delivery that contains only the contracted
  result plus trace references.

Acceptance criteria:

- a role’s effective model, prompt, tools, policy, budget, and output schema are
  inspectable before launch;
- parallel write workers cannot share the same working tree;
- the parent receives only the contracted result plus a trace reference;
- cancellation reliably terminates owned provider/process work;
- restart can recover or clearly mark orphaned tasks.

Relative effort: medium to large after P3/P4.

### P8 — Plugin bundles with manifests and trust

The current extension file is too small a unit for sharing a coherent setup.
Add plugins only after ownership and permissions exist.

A plugin should be able to bundle:

- Lisp components/extensions;
- skills and project rules;
- subagent roles;
- MCP server declarations;
- hooks and slash commands;
- frontend/provider registrations;
- settings schema and defaults;
- exercises/tests and migration code.

The manifest should declare identity, version, source, content hashes,
dependencies, requested capabilities, contributed components, and supported
cl-agent versions. Installation should be staged, reviewed, locked, and
reversible. Namespacing should prevent accidental collisions.

Claude Code plugins demonstrate the product value of bundling skills, agents,
hooks, and MCP servers. cl-agent can improve on that idea by making the bundle’s
live Lisp definitions, authority, source, and unload plan fully visible.

#### Implementation technique and sample

Use a data-only manifest and content-addressed installed payload. Installing a
plugin should resolve and verify a complete candidate set before any Lisp is
loaded. The lock record, not a mutable source directory, defines the active
plugin generation.

```lisp
(:schema-version 1
 :id "example/lisp-review"
 :version "1.2.0"
 :cl-agent "(>= 0.2.0)"
 :files (("extensions/review.lisp" :sha256 "<sha256>")
         ("skills/review/SKILL.md" :sha256 "<sha256>"))
 :contributes ((:extension "extensions/review.lisp")
               (:skill "skills/review")
               (:role "roles/reviewer.sexp"))
 :requires ((:plugin "example/common" :version "^1.0"))
 :capabilities (:read-workspace :process)
 :exercises ("exercises/smoke.sexp"))
```

```lisp
(defun install-plugin (source)
  (let* ((candidate (stage-plugin-source source))
         (manifest (read-validated-plugin-manifest candidate))
         (resolution (resolve-plugin-set manifest (read-plugin-lock))))
    (verify-plugin-files candidate manifest)
    (authorize-plugin-capabilities manifest)
    (probe-plugin-set-in-clean-image resolution)
    (with-mutation-transaction (:owner (plugin-owner-id manifest))
      (publish-plugin-payload candidate manifest)
      (write-plugin-lock-atomically resolution)
      (activate-plugin-components manifest))))
```

Do not allow manifest paths to escape the staged root, and do not run migration
code merely to inspect a package. Signatures can be added later; hashes and an
exact source/lock record are still required from the first version. If remote
installation is introduced, trust of the transport/source and trust of the
requested runtime capabilities must remain separate decisions.

#### Exact repository changes

- Add `src/plugins/{manifest,resolver,store,lifecycle}.lisp` and a versioned
  manifest schema. Start with local directory/archive sources; defer a registry
  service and marketplace UI.
- Store immutable payloads under `plugins/store/<content-digest>/`, manifests
  under the payload, and an atomic `plugins.lock` mapping plugin IDs to exact
  versions, digests, source references, capabilities, and dependency edges.
- Reject duplicate IDs, namespace collisions, dependency cycles, incompatible
  cl-agent versions, digest mismatches, absolute/parent paths, unknown
  contribution kinds, and undeclared files before activation.
- Bind P1 origin/owner while loading every contribution. Plugin removal calls
  P2 retirement/rollback for all owned components and leaves another plugin's
  shared dependency active while it is still referenced.
- Load plugin skills, rules, roles, and MCP declarations through their existing
  subsystem APIs rather than teaching the plugin manager their runtime
  semantics. The manager owns lifecycle and provenance only.
- Express upgrades as a mutation transaction: stage new set, run old-to-new
  data migrations in a bounded phase if declared, clean-image probe, activate,
  exercise, publish new lock, then retain the previous lock/generation for
  rollback.
- Add `plugin.list`, `plugin.inspect`, `plugin.install`, `plugin.upgrade`,
  `plugin.disable`, and `plugin.remove` commands/tools. Inspection must show
  source, hashes, requested/effective capabilities, dependencies, contributed
  components, and exercises before enablement.
- Add tests for malicious paths, digest mismatch, dependency resolution,
  collisions, capability denial, failed upgrade rollback, shared dependency
  retention, full owner cleanup, and reproduction from the lock record.

Acceptance criteria:

- install/upgrade/remove are transactions;
- the user sees requested capabilities before enabling the plugin;
- removing a plugin retires every component it owns;
- an exact lock record can reproduce the effective component set.

Relative effort: medium after P1/P2/P4.

### P9 — Complete MCP and structured/multimodal values

The MCP client currently registers only remote tools and converts only text
content blocks to one string (`src/mcp/client.lisp:51-62`). The MCP server
exports only tools.

Build:

- preserve structured tool results and content-block types end to end;
- support images, audio, embedded resources, and resource links where providers
  and frontends allow them;
- expose MCP resources as addressable read-only context resources;
- expose MCP prompts as namespaced commands/workflows;
- add resource subscriptions and connection health where supported;
- give each remote capability origin, trust, and permission metadata;
- lazily disclose large MCP schemas to control context cost.

Official Claude Code MCP support makes resources available as referenced
attachments and prompts as commands; those are worthwhile interoperability
targets. This is useful, but lower priority than making cl-agent’s own state
safe and inspectable.

#### Implementation technique and sample

Generalize the internal result before changing every provider. A compatibility
normalizer can wrap today's strings as one text block while MCP and future
tools return typed blocks and structured data.

```lisp
(defstruct content-block type text data media-type uri name metadata)
(defstruct tool-result content structured-value is-error-p metadata)

(defun normalize-tool-result (value)
  (typecase value
    (tool-result value)
    (string (make-tool-result
             :content (list (make-content-block :type :text :text value))))
    (t (make-tool-result
        :content (list (make-content-block :type :text
                                           :text (princ-to-string value)))))))

(defun provider-tool-result-message (provider tool-call result)
  (let ((normalized (normalize-tool-result result)))
    (encode-tool-result-blocks provider tool-call normalized)))
```

Keep structured values and blocks intact in durable events. At the provider
edge, negotiate capabilities: send native image/resource blocks where
supported, otherwise render an explicit bounded textual fallback or artifact
reference. Never silently drop a non-text block as
`mcp-content-blocks->text` does today.

Represent MCP resources and prompts as namespaced components:

```text
mcp-resource:docs/file:///guide.md
mcp-prompt:issue-tracker/triage
```

Resources should enter context only through an explicit read/reference action;
prompts should compile into a visible command/context contribution rather than
execute invisibly. Cache entries must retain server, URI, revision/ETag if
available, media type, subscription version, and policy decision.

#### Exact repository changes

- Add content block and tool result types in `src/content.lisp` early in ASDF
  load order. Change `call-tool` to return `tool-result`; provide
  `tool-result-text` and temporary string coercion helpers for old tests and
  extension callers.
- Update `run-tool-call`, hook contexts, task/session events, and every frontend
  to accept typed results. Redefine `:after-tool-call` as receiving
  `:tool-result`; during migration also include a derived `:result` string and
  deprecate mutation of that field.
- Add provider generics for supported input/output content types and block
  encoding. Update normalized message content from `STRING-OR-NIL` to either a
  string or block list, with per-provider compatibility tests.
- Replace `mcp-content-blocks->text` with a lossless MCP-to-content conversion
  covering text, image, audio, embedded resource, resource link, annotations,
  error state, and structured content. Unknown block types should be preserved
  as opaque metadata or reported, not discarded.
- Extend `mcp-connection` with server capabilities, resources, prompts,
  subscription state, and health. Register each discovered item as a P1
  component owned by the connection and retire all of them on disconnect.
- Add `list-mcp-resources`, `read-mcp-resource`, `list-mcp-prompts`, and
  `get-mcp-prompt` APIs/tools. If the pinned `cl-mcp` lacks a protocol feature,
  extend or upgrade that dependency behind capability checks rather than
  reaching into its private internals.
- Extend the MCP server to export cl-agent resources and prompts in addition to
  tools, using the same permission and redaction layer as local APIs.
- Store large binary blocks in P3's blob store and put digests/references in
  events. The web UI may request authorized blobs through a media endpoint;
  terminal UIs show metadata and a safe path/reference.
- Add round-trip fixtures for mixed text/image/resource results, structured
  values, unknown blocks, provider fallback, subscriptions, disconnect
  cleanup, large blobs, and server-side resources/prompts.

Relative effort: medium.

### P10 — Headless session API and a bounded management endpoint

`--mcp-serve` exposes tools, but it is not a session API. The Emacs integration
therefore offers either a one-shot subprocess or tool access inside another
chat host.

Build:

- a local, authenticated JSON-RPC/ACP-like service for session creation,
  prompt submission, streaming events, steering, cancellation, approvals,
  resume/replay, and component inspection;
- session leases so two clients cannot accidentally own one conversation;
- a non-interactive job mode with input/output contracts and stable exit
  statuses;
- optional authenticated evaluation against the active image with strict frame,
  source, output, concurrency, and timeout bounds;
- an Emacs client using the session API, not raw process scraping.

Do **not** make an unrestricted Swank/Slynk listener the default remote control
surface. It is excellent for a trusted developer, but it bypasses the component,
transaction, event, and permission abstractions that make the product
introspectable. If offered, keep it explicitly opt-in and local/trusted.

#### Implementation technique and sample

Run a session manager inside the long-lived image and expose a small versioned
RPC vocabulary. Transport and method semantics should be separate so Emacs can
use newline-delimited JSON over a local socket while the web UI uses HTTP/SSE.

```lisp
(defstruct session-lease id session-id client-id expires-at revision)

(defgeneric rpc-method (name parameters context))

(defmethod rpc-method ((name (eql :session/prompt)) parameters context)
  (let* ((session-id (required-parameter parameters :session-id))
         (lease (require-session-lease context session-id
                                       (getf parameters :lease-id)))
         (session (find-managed-session session-id)))
    (assert-lease-revision lease (getf parameters :expected-revision))
    (enqueue-session-input session (getf parameters :content)
                           :client-id (rpc-client-id context))))
```

Initial methods should be boring and explicit:

```text
session/create       session/list          session/inspect
session/acquire      session/renew         session/release
session/prompt       session/steer         session/cancel
session/subscribe    session/resume        session/branch
component/list       component/describe
approval/decide      command/invoke
job/run              job/status
```

Only one write lease controls a session at a time; any number of clients may
hold read subscriptions. A lease has an expiry and revision so a dead editor
does not own a session forever and a stale client cannot submit into a newer
conversation branch. Prompt submission returns an operation ID immediately;
events carry streaming output and completion.

For automation, `job/run` creates an ordinary durable session with a declared
input schema, role/policy, deadline, output schema, and artifact directory. Its
terminal event determines a stable process/RPC status; automation should not
scrape prose to decide success.

#### Exact repository changes

- Add `src/service/{manager,leases,rpc,transport,job}.lisp`. The manager owns a
  synchronized table of sessions and operations; it does not own conversation
  truth, which remains in the P3 store.
- Refactor `main.lisp` startup into reusable initialization and mode selection.
  Add `--serve`, `--socket`/`--listen`, `--auth-token-file`, and `--job FILE`
  without mixing them into provider construction logic.
- Define a versioned RPC envelope with request ID, method, parameters, client
  identity, protocol version, result/error, and trace ID. Validate sizes and
  schemas before method dispatch.
- Implement a local Unix-domain-socket transport where supported and
  loopback HTTP/SSE as the portable/web path. Require an owner-only token file;
  non-loopback access needs explicit hardened configuration rather than a flag
  that silently removes authentication.
- Add a session command queue so two RPC handler threads never run turns on one
  `agent-session` concurrently. Steering/cancellation may signal the active
  operation through its dedicated control channel.
- Reuse P4 approval requests and P6 view/event serializers. RPC clients receive
  redacted events according to identity and session access, not raw Lisp
  objects.
- Update Emacs integration to create/acquire a session, subscribe by last event
  ID, send prompts, render approval requests, and reconnect/resume. Keep the
  one-shot subprocess command as a simple fallback.
- If an image-eval method is added, put it in a separate disabled-by-default
  capability. Bound package, reader options (`*read-eval* nil` unless
  explicitly needed), output, time, thread, source forms, and result encoding;
  record it as a self-modifying/debug operation.
- Add protocol tests for invalid envelopes, auth, lease races and expiry,
  stale revision, reconnect catch-up, per-session serialization,
  cancellation, bounded payloads, job exit mapping, and server restart.

Relative effort: large, and depends on P3/P4.

### P11 — Lisp-native condition/restart debugging

Common Lisp’s condition and restart system is an underused differentiator.
Today many tool errors are flattened into strings in `call-tool`, which loses
condition type, stack, restarts, and structured recovery options.

Build:

- structured condition receipts with type, report, bounded stack snapshot,
  source locations, owning component, and available restarts;
- a frontend-neutral restart picker;
- the ability to ask an isolated reviewer to diagnose a suspended failure;
- validated recovery actions such as retry, supply value/arguments, run a
  repair form, skip, or abort;
- replayable records of the selected restart and result.

This should be later than basic transactions and permissions, but it would make
the agent feel like a true Lisp machine rather than a shell agent implemented
in Lisp.

#### Implementation technique and sample

A restart is dynamically scoped: it cannot be serialized and invoked after the
stack has unwound. The execution thread must stop inside `handler-bind`, publish
a serializable description of the condition and currently active restarts, and
wait on a bounded control channel. The selected restart is then invoked on that
same thread before leaving its dynamic extent.

```lisp
(defun call-with-interactive-recovery (session thunk)
  (handler-bind
      ((error
         (lambda (condition)
           (let* ((restarts (compute-restarts condition))
                  (options (loop for restart in restarts
                                 for id = (new-id "restart")
                                 collect (cons id restart)))
                  (receipt (condition-receipt condition options)))
             (record-session-event session :condition-signalled
                                   :status :waiting :payload receipt)
             (let ((choice (wait-for-restart-choice session receipt
                                                    :timeout 120)))
               (cond
                 ((assoc choice options :test #'equal)
                  (record-session-event session :restart-selected
                                        :payload (list :restart-id choice))
                  (invoke-restart (cdr (assoc choice options :test #'equal))))
                 (t
                  (invoke-restart (or (find-restart 'abort condition)
                                      (error condition))))))))))
    (funcall thunk)))

(defun read-config-value (key)
  (restart-case
      (error 'missing-config-value :key key)
    (use-value (value) :report "Supply a value for this operation." value)
    (retry () :report "Reload configuration and try again."
      (read-config-value key))
    (abort () :report "Abort the current operation." nil)))
```

Do not suspend on every `error`. Define recovery policy by condition type,
component, session mode, and whether an interactive frontend/lease exists.
Internal programming errors should normally capture diagnostics and abort the
operation; only deliberately established restarts should be user/model
selectable. Restart arguments require schemas and validation rather than
arbitrary forms.

Stack capture should be bounded and redacted. On SBCL, use implementation APIs
behind a portability layer to collect frame function/source summaries while
the stack is live. Never retain raw frame objects after resumption.

#### Exact repository changes

- Add `src/debug/{conditions,frames,recovery}.lisp`. Extend existing condition
  types with stable codes and structured fields while retaining human-readable
  reports.
- Change `call-tool` so it can return a structured condition result or re-signal
  into the recovery boundary instead of immediately flattening every handler
  error to a string. Preserve legacy string behavior for noninteractive
  sessions through a recovery policy.
- Establish `restart-case` at meaningful boundaries: provider retry, tool
  argument correction, permission denial feedback, missing config values,
  extension/mutation failure, and task cancellation. Do not synthesize a Retry
  button unless the operation defines a safe retry restart.
- Wrap task/tool/mutation execution with `call-with-interactive-recovery` on the
  owning execution thread. Add a bounded mailbox and cancellation/timeout so a
  disconnected UI cannot suspend a worker forever.
- Add `ui-condition-waiting` and restart-choice operations to the frontend/API.
  CLI may prompt synchronously; web/TUI show condition, frames, restart reports,
  and typed argument fields generated from schemas.
- Let an optional diagnostic subagent receive only the redacted receipt,
  relevant source snippets, and trace references. Its recommendation is not
  itself authority to invoke a restart.
- Record condition/restart events, but replay them as historical facts. Replay
  must never reconstruct an invokable restart token after the original dynamic
  scope has ended.
- Test nested handlers, restart argument validation, abort fallback, timeout,
  frontend disconnect, stack redaction, noninteractive behavior, and the
  impossibility of using an expired restart ID.

Relative effort: medium to large.

### P12 — Scenario/evaluation harness for changing mechanics

If users can replace planners, hooks, prompts, policies, and tools, they need a
way to know whether the new mechanics are better.

Build:

- declarative scenarios with a fixture workspace, component/config snapshot,
  scripted or live provider, task, event invariants, artifact expectations,
  budget, and score;
- deterministic trace tests for the agent loop;
- live-model evaluation runs kept separate from the offline suite;
- A/B comparison of two component generations on success, tool calls, tokens,
  latency, policy denials, and verification outcomes;
- regression promotion: turn a failed real session trace into a redacted local
  scenario.

This is the feedback loop that makes “changeable mechanics” sustainable rather
than merely possible.

#### Implementation technique and sample

Keep scenarios as inert data and run each in an isolated temporary workspace,
config directory, component generation, and event store. A scripted provider
drives deterministic loop tests; live providers are a separate, explicitly
costed suite.

```lisp
(:schema-version 1
 :id "edit-with-verification"
 :fixture "fixtures/small-project/"
 :generation "baseline"
 :provider (:kind :scripted :script "scripts/edit-with-verification.sexp")
 :request "Change FOO to return 42 and verify it."
 :policy-mode :accept-edits
 :limits (:requests 4 :tool-calls 8 :seconds 20 :tokens 12000)
 :expect (:terminal-status :succeeded
          :events ((:kind :tool-call-finished :component "tool:edit-file")
                   (:kind :tool-call-finished :component "tool:shell"))
          :files (("src/foo.lisp" :matches "return 42"))
          :invariants (:no-denied-capability :no-unknown-outcome)))
```

```lisp
(defun run-scenario (definition &key generation provider-override)
  (with-scenario-environment (environment definition generation)
    (let* ((session (make-scenario-session definition environment
                                           provider-override))
           (result (execute-scenario-request session definition))
           (trace (read-session-events (session-id session)))
           (assertions (evaluate-scenario-expectations definition trace
                                                        environment)))
      (make-scenario-result :id (getf definition :id)
                            :status (if (every #'assertion-passed-p assertions)
                                        :passed :failed)
                            :assertions assertions
                            :metrics (scenario-metrics session trace)
                            :trace-reference (session-id session)))))
```

Compare generations on a set of scenarios, not a single aggregate score. Show
per-scenario regressions and deltas in success, requests, tool calls, tokens,
latency, denials, unknown outcomes, and verification evidence. Repeated
live-model trials need variance/confidence reporting; one stochastic win should
not promote a generation.

Trace-to-scenario promotion should redact secrets and replace unstable values
with matchers. It should copy only authorized fixture artifacts, produce a
draft scenario, and require review before adding it to the deterministic suite.

#### Exact repository changes

- Add a separate `cl-agent/evals` ASDF system and
  `eval/{schema,runner,assertions,metrics,compare,promote}.lisp`. Do not load
  evaluation machinery into the normal executable.
- Extract or formalize the scripted/fake provider used by tests so scenarios
  can supply normalized assistant messages, chunks, tool calls, provider
  errors, and usage. Validate that the script is fully consumed.
- Build each scenario in a fresh `uiop:with-temporary-directory`, copy the
  fixture without `.git` unless the scenario requests it, bind
  `*config-directory*`, select a component generation, and use a dedicated
  event store. Deny ambient network by default.
- Implement event matchers for ordered subsequences, absence, parent/child
  relationships, status, component ID, capability decision, and bounded
  payload predicates. Add artifact/file digest and structured output matchers.
- Enforce request/tool/token/time/process-output budgets in the runtime, not
  only as post-run assertions. A budget breach should create a terminal event
  and cancel owned work.
- Add `make eval`, `make eval-live`, `cl-agent eval PATH`, comparison output in
  JSON plus readable Markdown, and a generation-promotion gate that requires a
  declared scenario set.
- Add a redaction/promote command taking a session trace and selected artifacts.
  It should identify values needing replacement, write a draft fixture/scenario
  under a review directory, and never alter the canonical suite automatically.
- Test the evaluator with intentionally passing/failing scenarios, nondeterminism
  detection, timeout/cancellation, budget breaches, generation selection,
  secret redaction, and machine-readable comparison stability.

Relative effort: medium once P1/P3 exist.

## Recommended delivery sequence

### Release 1: Reflection kernel

- green tests and CI;
- atomic durable writes;
- component descriptors, ownership, and origin tracking;
- a typed event bus with in-memory subscribers;
- `/components`, `component.list`, `component.describe`, and `/doctor`;
- no major UI rewrite yet.

### Release 2: Safe self-change

- staged extension proposals;
- clean-process compile/load probe;
- live mutation transaction and component diff;
- exercises, commit, discard, and readable mutation journal;
- owner-aware unload/reload;
- minimal pristine rescue start.

### Release 3: Durable operation

- append-only session/event store;
- resume, replay, branch, export, and turn checkpoints;
- direct file-edit receipts and rewind;
- compaction as a durable projection;
- web timeline and session browser.

### Release 4: Authority and richer orchestration

- component effect metadata;
- permission modes/rules and approval events;
- shell sandbox;
- declarative child roles, output contracts, cancellation, and worktree
  isolation;
- task tree UI.

### Release 5: Ecosystem

- context layers, path rules, memory, and automatic compaction;
- plugins and lock records;
- full MCP resources/prompts/content blocks;
- headless session API and richer Emacs integration;
- condition/restart debugger and scenario evaluations.

## Suggested source boundaries

`src/repl.lisp` is now 1,467 lines and owns session data, planning, task
persistence, context reporting/compaction, side completions, review, shell
inspection, tool dispatch, the core turn loop, subagents, slash commands, and
the outer REPL. That concentration will make the proposed features hard to
change independently.

Extract along behavior boundaries as the new abstractions land:

| Proposed module | Responsibility |
|---|---|
| `src/components.lisp` | Component descriptors, registry adapters, ownership, graph, health |
| `src/events.lisp` | Event types, IDs, publication, subscribers, redaction |
| `src/store/` | Atomic append/store, blobs, schemas, migration, recovery |
| `src/session.lisp` | Session model, message projection, stats, lifecycle |
| `src/context.lisp` | Context layers, contributors, budgeting, compaction projection |
| `src/policy.lisp` | Capabilities, rules, decisions, approvals |
| `src/execution.lisp` | Tool validation/execution and receipts |
| `src/orchestration.lisp` | Planning, review, budget review, task records |
| `src/tasks/` | Roles, child tasks, scheduler, cancellation, structured yields |
| `src/mutation/` | Proposals, definition capture, exercises, journal, generations |
| `src/commands.lisp` | Slash/application command registry and dispatch |
| `src/repl.lisp` | Thin interactive composition loop |

This should be an interface-led extraction, not a standalone cleanup rewrite.
Each new feature can move one coherent responsibility and its tests.

## What not to build next

### More providers

The provider protocol already proves the abstraction. Another provider adds
reach but does little for the project’s differentiator. Add one only when it
forces a useful protocol capability such as native compaction, structured
output, prompt caching metrics, or multimodal values.

### Unrestricted multi-agent teams

The repo has a safe synchronous child primitive. Parallel agents with shared
write access would multiply the current deficits in persistence, policy,
rollback, and provenance. Build durable tasks, capability inheritance,
cancellation, and worktree isolation first.

### A full plugin marketplace

Packaging before component ownership and unload semantics would make installs
easy and removal unreliable. Establish the plugin format and local install
transactions before discovery/marketplace features.

### Recursive inference/RLM

Autolith’s bounded recursive inference is interesting, especially for large
contexts, but cl-agent first needs explicit context objects, contracts, trace
storage, and hierarchical budgets. Otherwise it is another hidden inference
path that is hard to inspect.

### UI polish disconnected from mechanics

Continue fixing correctness bugs, but defer a major visual rewrite until the UI
can render common component/event/session APIs. Otherwise the web, TUI, and
future Emacs surfaces will each invent their own state model.

### Raw remote image access as the main API

Swank/Slynk can remain a developer option. The product API should preserve
transactions, permissions, redaction, event logging, and session ownership.

## The first concrete PR I would make

Keep the first implementation deliberately small and non-disruptive:

1. Fix the three current test failures and add CI.
2. Add `src/components.lisp` with a `component-descriptor` data structure,
   stable IDs, and a process-wide descriptor table.
3. Bind `*registration-origin*` around core startup, extension loading, and MCP
   connection registration.
4. Teach existing registries to publish descriptors while retaining their
   current APIs.
5. Add `list-components` and `describe-component` Lisp functions plus read-only
   model tools and `/components`.
6. Add tests that every built-in tool/provider/frontend/hook point/command has
   an origin and a unique ID.
7. Add a minimal typed event publisher and emit `:component-registered`,
   `:component-replaced`, and `:component-unregistered` events in memory.

That PR would not yet solve rollback. It would create the vocabulary and
ownership information required to solve rollback correctly in the following
PR, while immediately making the running agent more introspectable.

## Bottom line

cl-agent already has enough breadth. Its highest-leverage next move is depth:

- unify its extension points as inspectable components;
- unify its behavior as replayable events;
- make mutations transactional and reversible;
- make authority deterministic;
- persist sessions before adding autonomous concurrency;
- let every UI inspect and operate those same mechanics.

If only one major feature is selected, choose **transactional self-modification
with component ownership, exercises, and rollback**. It most directly fulfills
the project’s promise and turns Common Lisp’s live image from a clever demo
into a dependable product capability.
