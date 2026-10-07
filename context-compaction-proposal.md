# Feature Proposal: Automatic Context-Window-Aware Compaction

## The Problem

The single most impactful gap found in the cl-agent codebase is the
**complete absence of automatic context management**. As conversations
grow — especially tool-heavy investigation or coding sessions, which are
exactly this agent's core use case — the message history grows unbounded
until the provider rejects the request with a hard error, aborting the
turn entirely. The agent has no awareness of its context limit, no way to
learn it, and no mechanism to act on it.

## Evidence from the Codebase

### 1. The provider protocol has no context-window accessor

`src/providers/provider.lisp` (all 156 lines) defines exactly eight
generic functions: `chat`, `chat-stream`, `provider-default-model`,
`provider-display-name`, `provider-api-key-env-var`,
`provider-ensure-ready`, `provider-list-models`, and
`provider-for-model`. **None expose the model's context-window
capacity.** The codebase acknowledges this gap explicitly in two places:

- `session-context-report` at `src/repl.lisp:609` prints: *"Context-window
  capacity: not advertised by the active provider/model, so no percentage
  is shown."*
- `src/repl.lisp:1373` states: *"tokenizers and do not currently expose
  their context-window size here."*

### 2. Compaction exists but is deliberately manual-only

`compact-session-history` at `src/repl.lisp:637` can summarize
conversation history into a continuity note. Its own docstring is
explicit: *"This function is intentionally called only by the /COMPACT
slash command. It does not run as part of the agent loop and therefore
cannot cause a model to compact its own context autonomously."*

### 3. Token estimation is crude and used for nothing actionable

`approximate-token-count` at `src/repl.lisp:581` is literally
`(ceiling characters 4)` — four characters per token. It feeds only the
`/context` display report, never any decision logic.

### 4. History grows without bound inside the turn loop

In `run-agent-turn` (starting at `src/repl.lisp:1000`), every iteration
appends the assistant message to `session-messages` via
`(setf (session-messages session) (append (session-messages session)
(list assistant-message)))`, and every tool result is appended the same
way via `(list (run-tool-call session tc))`. The loop only terminates
when the model stops calling tools or `max-tool-iterations` is hit.
Nothing prevents the accumulated history from exceeding the provider's
limit.

### 5. When the limit IS hit, it's a hard crash

Inside `run-agent-turn`, the `provider-error` handler at approximately
`src/repl.lisp:1020` calls `(run-hook :on-error c)`,
`(ui-error frontend c)`, and then
`(return-from run-agent-turn (finish-agent-turn session nil "blocked"
(princ-to-string c)))`. A context-overflow error kills the turn dead —
and the overflowing history is still there for the next attempt, so the
next turn fails too.

### 6. Usage stats are unreliable, compounding the blindness

`session-note-request` at `src/repl.lisp:662` only accumulates token
counts when the assistant message reports `:usage`. Its docstring admits
streaming commonly yields NIL — making even the estimated totals "a lower
bound, not wrong, just incomplete."

## What the Feature Does

The feature has three integrated pieces, all fitting cleanly into existing
extension seams.

### Piece 1 — `provider-context-window` protocol method

**File:** `src/providers/provider.lisp`

Add one generic function to the `llm-provider` protocol:

```lisp
(defgeneric provider-context-window (provider)
  (:documentation
   "Return the context-window size in tokens for PROVIDER's current
model, or NIL if unknown. This lets the agent loop estimate how full
the context is and trigger compaction before a request exceeds the
limit.")
  (:method ((provider llm-provider)) nil))
```

Each concrete provider overrides it with model-specific knowledge:
OpenAI-compatible providers use a static alist (e.g. `(("gpt-4o" .
128000) ("gpt-4o-mini" . 128000))`); Ollama reads the model's modelfile;
Anthropic uses known Claude family limits. The default `nil` preserves
backward compatibility — if a provider doesn't implement it, behavior is
unchanged from today.

### Piece 2 — Automatic compaction check in the turn loop

**File:** `src/repl.lisp`, inside `run-agent-turn`

At the top of each iteration of the turn loop, before the `chat-stream`
call, insert a call to a new `auto-compact-if-needed` function. That
function computes the estimated context size (reusing the existing
`message-context-characters`, `approximate-token-count`, and tool-schema
accounting already in `session-context-report`), compares it against
`provider-context-window` scaled by a configurable threshold (default
80%), and if exceeded, invokes compaction automatically — not as a slash
command, but as a transparent part of the loop. This sits right before
the existing `:before-request` hook chain at `src/repl.lisp:1014`.

### Piece 3 — Sliding-window compaction strategy

**File:** `src/repl.lisp` (`compact-session-history`)

The current compaction at `src/repl.lisp:654` collapses *all* history
into `[initial-system, summary]`, losing structured tool-call messages
the model needs for mid-task continuity. The improvement: summarize only
the *older* portion of the history (everything before the last N
messages), then prepend the summary to the preserved recent messages,
producing `[initial-system, compacted-summary,
recent-N-messages-verbatim]`. The `session-history-transcript` function
at `src/repl.lisp:626` already renders history for summarization; it
would be called on just the older slice. A new `:keep-recent` keyword
argument on `compact-session-history` controls how many trailing
messages survive intact.

## Why This Is the Most Impactful Feature

- **It prevents the agent's hardest failure mode.** Context overflow is
  the one error that both kills the current turn AND makes the next turn
  fail too (the history is still too big). No other gap found causes this
  cascading failure.
- **It directly extends existing infrastructure.** `compact-session-history`,
  `approximate-token-count`, `message-context-characters`,
  `session-context-report`, and `session-history-transcript` all already
  exist — this feature wires them into the loop and makes them proactive
  rather than reactive.
- **It fits the provider protocol philosophy perfectly.** The file header
  of `provider.lisp` says the protocol is designed so that "repl.lisp,
  main.lisp, and every tool only ever call these five functions; none of
  them know or care which concrete class they're talking to." Adding
  `provider-context-window` as a sixth optional, nil-defaulting method is
  exactly this pattern.
- **It helps the agent do long, complex jobs** — the multi-tool
  investigations, refactoring tasks, and codebase explorations where
  context pressure is most acute.

## How It Integrates

| Component | File | Seam |
|---|---|---|
| `provider-context-window` generic | `src/providers/provider.lisp` | New protocol method (nil default) |
| Per-provider overrides | `src/providers/openai.lisp`, `anthropic.lisp`, `ollama.lisp`, etc. | Specialize the new generic |
| `auto-compact-if-needed` | `src/repl.lisp` | New function, called at top of `run-agent-turn` loop body |
| Sliding-window compaction | `src/repl.lisp` (`compact-session-history`) | Extends existing function with `:keep-recent` parameter |
| Threshold config | `src/config.lisp` | New `:context-compaction-threshold` key (default 0.8) |
