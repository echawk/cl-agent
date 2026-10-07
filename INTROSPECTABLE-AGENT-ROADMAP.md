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
 :source      (:pathname "src/tools/file-tool.lisp" :digest "...")
 :version     1
 :status      :active
 :enabled-p   t
 :provides    (:filesystem-read)
 :requires    ()
 :effects     (:read-files)
 :config      (...)
 :health      (:status :ok :checked-at ...))
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
 :payload    (...)
 :usage      (...)
 :redactions (...))
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

Acceptance criteria:

- every model-visible tool can be traced to core source, an extension/plugin,
  or a specific MCP connection;
- every active hook shows its order and owner;
- disabling an owner identifies all components it would retire;
- all three frontends can list/describe components through the same API.

Relative effort: medium.

### P2 — Transactional self-modification, exercises, and rollback

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
