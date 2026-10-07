# Implementation Strategy: Automatic Context-Window-Aware Compaction

This document provides step-by-step implementation guidance for every
component of `context-compaction-proposal.md`. It is written so that a
significantly less capable model could execute each piece without
ambiguity — every section specifies the exact file to modify, the exact
function signatures, the exact insertion points (with surrounding code
for context), what each function does internally, the dependency
ordering between pieces, and concrete acceptance criteria.

**Read this entire document before starting.** The pieces have a strict
dependency order: Piece 1 (protocol method) must exist before Piece 2
(auto-compact) can call it; Piece 3 (sliding-window compaction) must
exist before Piece 2 calls it; the config wiring (under Piece 2) must
exist before `auto-compact-if-needed` can read the threshold. The
recommended implementation order is: Piece 1 → Piece 3 → config wiring
→ Piece 2 → per-provider overrides → tests.

---

## Dependency Graph

```
Piece 1 (provider-context-window generic + nil default)
   │
   ├──► Per-provider overrides (openai, anthropic, ollama, reallms, xai, apfel)
   │
Piece 3 (sliding-window compact-session-history with :keep-recent)
   │
Config wiring (:context-compaction-threshold → session slot)
   │
Piece 2 (auto-compact-if-needed, inserted into run-agent-turn)
   │
Tests (one test file section per piece)
```

---

## Piece 1 — `provider-context-window` Protocol Method

### Goal

Add a new generic function to the `llm-provider` protocol that returns
the context-window size (in tokens) for the provider's current model,
or `nil` if unknown. The nil default preserves backward compatibility —
providers that don't implement it behave exactly as they do today.

### File to modify

`src/providers/provider.lisp`

### What to do

Add the following `DEFGENERIC` form at the **end** of the file, after
the existing `provider-for-model` generic (which is currently the last
form in the file — it starts around line 143). Place it after the
closing parenthesis of `provider-for-model`.

Insert this exact form:

```lisp
(defgeneric provider-context-window (provider)
  (:documentation
   "Return the context-window size in tokens for PROVIDER's current
model, or NIL if unknown. This lets the agent loop estimate how full
the context is and trigger compaction before a request exceeds the
limit.")
  (:method ((provider llm-provider)) nil))
```

### Why this exact form

- `(:method ((provider llm-provider) nil))` gives a nil default on the
  base class, mirroring how `provider-list-models` (also in this file)
  returns nil by default. Any provider that doesn't override this is
  unchanged in behavior.
- The function takes only `provider` — it reads the model from
  `(provider-model provider)`, the same accessor every other protocol
  method uses (the `model` slot defined at the top of this file).
- It returns an integer (token count) or nil. Nothing else.

### Also: update the file header comment

The file header comment (lines 1–14) says "every provider implements
exactly the same five generic functions." After this change there are
nine. Update the header to say "nine generic functions" and add
`provider-context-window` to the list if the header enumerates them.
Look at the actual text: the header says "five generic functions" in
the context of the original five. Change the number to reflect reality
(or just say "the generic functions below" to avoid future drift).

### Acceptance criteria

1. After loading the system, `(provider-context-window (make-instance 'llm-provider))` returns `nil`.
2. The symbol `provider-context-window` is fbound and is a standard generic function.
3. No existing tests break (the nil default means no provider changes behavior yet).
4. `(lisp-apropos "provider-context-window")` finds the symbol in the `cl-agent` package.

---

## Per-Provider Overrides

### Goal

Each concrete provider that has reliable context-window knowledge
overrides `provider-context-window` to return the correct value for
its current model.

### General approach

Each override looks up `(provider-model provider)` in a static alist of
known model→window-size pairs, returning nil for unknown models. The
static-alist approach is what the proposal specifies — model context
windows are public knowledge that changes rarely, and a network call
to look them up would be inappropriate in the hot path (the auto-compact
check runs on every loop iteration).

### File: `src/providers/openai.lisp`

Add after the existing `provider-api-key-env-var` method (around line
15), before the `register-provider-class` call:

```lisp
(defmethod provider-context-window ((provider openai-provider))
  (let ((model (provider-model provider)))
    ;; Context windows are input+output combined, from OpenAI's docs.
    (cond
      ((or (search "gpt-4o-mini" model) (search "gpt-4o" model)) 128000)
      ((or (search "gpt-4.1-mini" model) (search "gpt-4.1" model)) 1047576)
      ((or (search "o4-mini" model) (search "o3" model)) 200000)
      (t nil))))
```

**Note:** `search` is used (not `string=`) because model names often
have date suffixes like `gpt-4o-2024-08-06`. The `search` calls should
go from most-specific to least-specific — put `gpt-4o-mini` before
`gpt-4o` because `gpt-4o` is a substring of `gpt-4o-mini`. Use the
exact `cond` ordering shown above.

### File: `src/providers/anthropic.lisp`

Add after the existing `provider-api-key-env-var` method (around line
22), before `*anthropic-api-version*`:

```lisp
(defmethod provider-context-window ((provider anthropic-provider))
  (let ((model (provider-model provider)))
    (cond
      ((search "claude-sonnet-4" model) 200000)
      ((search "claude-opus-4" model) 200000)
      ((search "claude-haiku" model) 200000)
      ((search "claude-3-5" model) 200000)
      ((search "claude-3" model) 200000)
      (t nil))))
```

### File: `src/providers/ollama.lisp`

Ollama is special: it can query the running model's modelfile to get
the actual context window. However, the proposal says "reads the
model's modelfile." The simplest reliable approach: query Ollama's
native `/api/show` endpoint, which returns the model's parameters
including `num_ctx`.

Add after the existing `provider-display-name` method (around line 13),
before the `*ollama-start-timeout*` defparameter:

```lisp
(defmethod provider-context-window ((provider ollama-provider))
  "Query Ollama's /api/show endpoint for the model's num_ctx parameter.
Returns nil if the server is unreachable or the parameter is absent."
  (handler-case
      (multiple-value-bind (body status)
          (drakma:http-request
           (concatenate 'string (ollama-api-root provider) "/api/show")
           :method :post
           :content-type "application/json"
           :content (json-encode (jobj "model" (provider-model provider)))
           :connection-timeout 3)
        (when (= status 200)
          (let* ((decoded (json-decode (if (stringp body) body
                                            (flexi-streams:octets-to-string body :external-format :utf-8))))
                 (params (jget decoded "parameters")))
            ;; /api/show returns "parameters" as a string like
            ;; "num_ctx 8192\nnum_keep 5\n..." — parse num_ctx out of it.
            (when params
              (let ((match (search "num_ctx " params)))
                (when match
                  (let* ((start (+ match (length "num_ctx ")))
                         (rest (subseq params start))
                         (end (or (position #\Newline rest) (length rest))))
                    (parse-integer (subseq rest 0 end) :junk-allowed t))))))))
    (error () nil)))
```

**Important:** The `ollama-api-root` helper already exists in this file
(line 31) — it strips the `/v1` suffix from the base URL to get the
native API root. Use it, do not redefine it. The `jobj`, `json-encode`,
and `json-decode` functions are already available in the `cl-agent`
package. The `handler-case` wrapping means any failure (server down,
unexpected response shape) safely returns nil — auto-compaction simply
won't trigger, which is the correct degraded behavior.

### File: `src/providers/reallms.lisp`

REALLMS proxies various models. Return nil — we can't know which
underlying model is being used or its context window. Do **not** add a
method. The base-class nil default is correct.

### File: `src/providers/xai.lisp`

Add after the existing `provider-api-key-env-var` method, before
`register-provider-class`:

```lisp
(defmethod provider-context-window ((provider xai-provider))
  (let ((model (provider-model provider)))
    (cond
      ((search "grok-4" model) 256000)
      ((search "grok-3" model) 131072)
      ((search "grok-2" model) 131072)
      (t nil))))
```

### File: `src/providers/apfel.lisp`

Add after the existing `provider-display-name` method, before
`*apfel-start-timeout*`:

```lisp
(defmethod provider-context-window ((provider apfel-provider))
  ;; The file header already documents: 4096 on macOS 26, 8192 on
  ;; macOS 27+. We can't detect the OS version here, so return the
  ;; conservative (smaller) value. Better to compact early than late.
  4096)
```

### Acceptance criteria

1. `(provider-context-window (make-provider :openai :model "gpt-4o"))` returns `128000`.
2. `(provider-context-window (make-provider :anthropic :api-key "x"))` returns `200000`.
3. `(provider-context-window (make-provider :xai :api-key "x" :model "grok-4-fast"))` returns `256000`.
4. `(provider-context-window (make-provider :reallms :api-key "x"))` returns `nil` (no method, base default).
5. An unknown model string on any provider returns `nil`.
6. For Ollama: if the server is unreachable, `provider-context-window` returns `nil` (does not signal an error).

---

## Piece 3 — Sliding-Window Compaction Strategy

### Goal

Modify `compact-session-history` so it summarizes only the *older*
portion of the conversation history, preserving the most recent N
messages verbatim. The result is `[initial-system, compacted-summary,
recent-N-messages-verbatim]` instead of the current
`[initial-system, summary]`.

### File to modify

`src/repl.lisp`

### Current state of the function

`compact-session-history` is at approximately line 637. Its current
signature is:

```lisp
(defun compact-session-history (session)
```

It currently:
1. Computes `before` token count of all messages.
2. Calls `session-complete` with a summarization prompt over
   `(session-history-transcript session)` — the *full* history.
3. If the summary is empty, returns `(values nil before before)`.
4. Otherwise, sets `session-messages` to `(list initial-system
   compacted-message)`.
5. Returns `(values t before after)`.

### New signature

Change the lambda list to:

```lisp
(defun compact-session-history (session &key (keep-recent 0))
```

The `:keep-recent` keyword argument (default 0) controls how many
trailing messages survive intact. A default of 0 means "compact
everything" — identical to the old behavior. This preserves backward
compatibility for the existing `/compact` slash command (which calls
`compact-session-history` with no keyword).

### New implementation

Replace the body of `compact-session-history` with this exact logic:

```lisp
(defun compact-session-history (session &key (keep-recent 0))
  "Replace prior conversation history with a model-written continuity
summary, optionally preserving the most recent KEEP-RECENT messages
verbatim.

When KEEP-RECENT is 0 (the default), all history after the initial
system prompt is summarized — this is the original /COMPACT behavior.
When KEEP-RECENT is positive, the function splits the history into
three parts:

  1. The initial system prompt (always preserved).
  2. The older messages (everything between the initial system prompt
     and the last KEEP-RECENT messages) — these are summarized.
  3. The last KEEP-RECENT messages — these are preserved verbatim.

The result is [initial-system, compacted-summary, recent-N-messages],
giving the model both the compressed context and the fresh tool calls /
responses it needs for mid-task continuity."
  (let* ((all-messages (session-messages session))
         (initial-system (first all-messages))
         (rest-messages (rest all-messages))
         ;; Split: older messages to summarize vs. recent ones to keep.
         (recent-count (min keep-recent (length rest-messages)))
         (older-messages (if (plusp recent-count)
                             (subseq rest-messages 0 (- (length rest-messages) recent-count))
                             rest-messages))
         (recent-messages (if (plusp recent-count)
                              (subseq rest-messages (- (length rest-messages) recent-count))
                              nil))
         (before (approximate-token-count
                  (loop for message in all-messages
                        sum (message-context-characters message)))))
    ;; If there's nothing to summarize, no-op.
    (if (null older-messages)
        (values nil before before)
        (let* (;; Render only the older messages for summarization.
               ;; session-history-transcript renders (session-messages session),
               ;; so temporarily bind it to just the older slice.
               (summary (session-complete
                         (format nil "Summarize this coding-agent conversation for a future continuation. Preserve the user's goals and constraints, decisions made, files and code changed, exact commands or tool evidence that matter, unresolved work, and the next useful step. Do not address the user, do not add speculation, and do not call tools. Write a concise factual continuity note in plain text.~%~%Conversation:~%~a"
                                 (render-messages-transcript older-messages))
                         :system "You compact coding-agent conversation history. Return only a precise continuity summary.")))
          (if (or (null summary) (zerop (length (string-trim " " summary))))
              (values nil before before)
              (let* ((compacted-message
                       (list :role "system"
                             :content (format nil "[Context compaction]~%~a" summary)))
                     (new-messages (list* initial-system
                                          compacted-message
                                          recent-messages)))
                (setf (session-messages session) new-messages)
                (values t before
                        (approximate-token-count
                         (loop for message in (session-messages session)
                               sum (message-context-characters message)))))))))))
```

### Helper: `render-messages-transcript`

The existing `session-history-transcript` (line 626) renders
`(session-messages session)` — it takes a session, not a message list.
We need to render an arbitrary list of messages. Rather than modifying
`session-history-transcript` (which would change the `/compact` display
path), add a small helper:

Place this **immediately before** `compact-session-history` (i.e.,
right after `session-history-transcript`):

```lisp
(defun render-messages-transcript (messages)
  "Render a list of message plists as text for summarization.
This is the message-list counterpart of SESSION-HISTORY-TRANSRIPT
(which takes a session and renders its full history). Used by
COMPACT-SESSION-HISTORY's sliding-window strategy to summarize only
a slice of the conversation."
  (with-output-to-string (out)
    (dolist (message messages)
      (format out "~a: ~a~%"
              (string-upcase (or (getf message :role) "unknown"))
              (or (getf message :content) ""))
      (dolist (call (getf message :tool-calls))
        (format out "ASSISTANT TOOL CALL: ~a ~a~%"
                (getf call :name) (json-encode (getf call :arguments)))))))
```

### Refactor `session-history-transcript` to use it (optional but recommended)

Optionally, refactor `session-history-transcript` to delegate to
`render-messages-transcript`:

```lisp
(defun session-history-transcript (session)
  "Render SESSION's full history for a user-requested compaction summary."
  (render-messages-transcript (session-messages session)))
```

This eliminates duplicated formatting logic. If you do this, make sure
the output is byte-identical (it will be — the format directives are
the same).

### Update the `/compact` slash command label

The `/compact` slash command (around line 1378) creates its summary
message with the prefix `"[User-requested context compaction]"`. The
new sliding-window compaction (called automatically) uses the prefix
`"[Context compaction]"` (without "User-requested"). This distinction
lets the model (and the user, if they inspect history) tell apart
user-triggered vs. automatic compactions. No change is needed to the
slash command itself — it calls `(compact-session-history session)`
which defaults `keep-recent` to 0, preserving its current behavior.

### Acceptance criteria

1. Calling `(compact-session-history session)` with no `:keep-recent`
   produces identical behavior to before (summary of everything,
   `[initial-system, summary]`).
2. Calling `(compact-session-history session :keep-recent 4)` on a
   session with 10 messages produces `[initial-system, summary,
   msg-7, msg-8, msg-9, msg-10]` (the last 4 messages preserved
   verbatim).
3. Calling `(compact-session-history session :keep-recent 4)` on a
   session with only 3 messages (system + 2 others) does nothing —
   `older-messages` is nil, returns `(values nil before before)`.
4. The summary is generated from only the older messages, not the
   recent ones (verify by mocking `session-complete` and checking the
   transcript it receives does not contain the recent messages'
   content).
5. The function still returns `(values compacted-p before-tokens
   after-tokens)`.
6. `(render-messages-transcript (list (list :role "user" :content "hello")))`
   returns a string containing `"USER: hello"`.

---

## Config Wiring — `:context-compaction-threshold`

### Goal

Add a config key `:context-compaction-threshold` (a float, default
0.8) that controls what fraction of the context window must be filled
before auto-compaction triggers. Wire it from the config file through
`make-session` into a session slot.

### File 1: `src/config.lisp`

In the docstring of `load-user-config` (which enumerates all
recognized keys), add a new key entry. Find the section listing
`:MAX-TOOL-ITERATIONS` and add this entry after it:

```
  :CONTEXT-COMPACTION-THRESHOLD  float between 0.0 and 1.0; when the
                   estimated context size exceeds this fraction of the
                   provider's context window, the agent automatically
                   compacts older history before the next request
                   (default 0.8, i.e. compact at 80% full). Set to 1.0
                   to effectively disable auto-compaction.
```

### File 2: `src/repl.lisp` — Add session slot

In the `agent-session` class definition (starts at line 167), add a
new slot after `max-tool-iterations`:

```lisp
   (context-compaction-threshold :initarg :context-compaction-threshold
                                  :initform 0.8
                                  :accessor session-context-compaction-threshold
                                  :documentation "Fraction of the
provider's context window at which automatic compaction triggers
(default 0.8). 0 disables auto-compaction entirely.")
```

### File 3: `src/repl.lisp` — Update `make-session`

In `make-session` (starts at line 305), add `context-compaction-threshold`
to the keyword parameters and pass it through to `make-instance`. The
current signature is:

```lisp
(defun make-session (provider &key frontend system-prompt (tools (list-tools)) max-tool-iterations orchestration-mode orchestration-tool-limit
                              (subagent-depth 0) (max-subagent-depth 1) subagent-model-profiles)
```

Change it to:

```lisp
(defun make-session (provider &key frontend system-prompt (tools (list-tools)) max-tool-iterations orchestration-mode orchestration-tool-limit
                              (subagent-depth 0) (max-subagent-depth 1) subagent-model-profiles
                              context-compaction-threshold)
```

And in the `make-instance` call inside `make-session`, add:

```lisp
                  :context-compaction-threshold (or context-compaction-threshold 0.8)
```

Place this alongside the other `:initarg` keyword arguments passed to
`make-instance`.

### File 4: `src/main.lisp` — Wire config to session

In `cli-handler` (around line 106), the `make-session` call passes
config values. Add the new key:

Find this call:
```lisp
                (run-repl (make-session provider
                                        :frontend (make-frontend (resolve-ui-keyword (clingon:getopt cmd :ui) config))
                                        :system-prompt (config-value config :system-prompt)
                                        :orchestration-mode (config-value config :orchestration-mode)
                                        :orchestration-tool-limit (config-value config :orchestration-tool-limit)
                                        :max-tool-iterations (config-value config :max-tool-iterations)
                                        :max-subagent-depth (config-value config :max-subagent-depth 1)
                                        :subagent-model-profiles (config-value config :subagent-model-profiles))
```

Add one more line before the closing paren:
```lisp
                                        :context-compaction-threshold (config-value config :context-compaction-threshold 0.8)
```

### Acceptance criteria

1. A session created with no config has `(session-context-compaction-threshold session)` equal to `0.8`.
2. Setting `:context-compaction-threshold 0.5` in config.lisp makes the session's threshold `0.5`.
3. `(make-session (make-instance 'ollama-provider) :context-compaction-threshold 0.9)` produces a session with threshold `0.9`.
4. A threshold of `0.0` or `1.0` is accepted without error.

---

## Piece 2 — Automatic Compaction Check in the Turn Loop

### Goal

Add an `auto-compact-if-needed` function that runs at the top of each
iteration of the `run-agent-turn` loop, before the `:before-request`
hook chain. It estimates context size, compares it against the
provider's context window scaled by the threshold, and if exceeded,
invokes `compact-session-history` with a `:keep-recent` value.

### File to modify

`src/repl.lisp`

### Step 2a: Define `estimated-context-tokens`

First, extract the token-estimation logic that currently lives inside
`session-context-report` into a reusable function. This avoids
duplicating the message-token + tool-token computation.

Place this **immediately before** `auto-compact-if-needed` (and after
`session-context-report`):

```lisp
(defun estimated-context-tokens (session)
  "Return the estimated total token count of what the next model request
will carry: conversation history tokens plus tool-schema tokens.
Reuses MESSAGE-CONTEXT-CHARACTERS, APPROXIMATE-TOKEN-COUNT, and
TOOL-JSON-SCHEMA — the same accounting SESSION-CONTEXT-REPORT uses for
its /context display."
  (let ((message-tokens (approximate-token-count
                          (loop for message in (session-messages session)
                                sum (message-context-characters message))))
        (tool-tokens (approximate-token-count
                      (loop for tool in (session-tools session)
                            sum (length (json-encode (tool-json-schema tool)))))))
    (+ message-tokens tool-tokens)))
```

### Step 2b: Define `auto-compact-if-needed`

Place this immediately after `estimated-context-tokens`:

```lisp
(defun auto-compact-if-needed (session)
  "Check whether SESSION's estimated context is approaching the
provider's limit and, if so, compact automatically.

Computes the estimated context size (conversation + tool schemas),
compares it against (provider-context-window * threshold), and if
exceeded, calls COMPACT-SESSION-HISTORY with a :KEEP-RECENT value that
preserves the most recent messages verbatim.

This is a no-op (returns NIL) when:
  - The threshold is 0 (auto-compaction disabled).
  - The provider returns NIL for PROVIDER-CONTEXT-WINDOW (unknown limit).
  - The estimated size is below the threshold.

Returns T if compaction occurred, NIL otherwise. Never signals an
error — if the summarization call fails, the turn continues with the
uncompacted history (the model may still hit the limit, but that's
better than aborting the turn here)."
  (let ((threshold (session-context-compaction-threshold session)))
    (when (and threshold
               (plusp threshold)
               (not (>= threshold 1.0)))
      (let ((window (provider-context-window (session-provider session))))
        (when window
          (let* ((estimated (estimated-context-tokens session))
                 (limit (floor (* window threshold))))
            (when (> estimated limit)
              ;; Keep roughly 25% of the window's worth of recent messages,
              ;; or at least 6 messages (system + a few tool round-trips).
              ;; This is a heuristic: we want to preserve enough recent
              ;; context for mid-task continuity without re-overflowing.
              (let ((keep-recent (max 6 (count-recent-messages-for-window session window))))
                (handler-case
                    (multiple-value-bind (compacted-p before after)
                        (compact-session-history session :keep-recent keep-recent)
                      (when compacted-p
                        (ui-system (session-frontend session)
                                   (format nil "[context] Auto-compacted: ~d -> ~d tokens (window ~d, threshold ~,2F)."
                                           before after window threshold))
                        t))
                  (error (c)
                    (ui-system (session-frontend session)
                               (format nil "[context] Auto-compaction attempted but failed: ~a" c))
                    nil)))))))))))
```

### Step 2c: Define `count-recent-messages-for-window`

This helper determines how many recent messages to preserve. The goal:
keep enough messages that the model has its recent tool calls and
results for continuity, but not so many that the post-compaction
context is still over the limit.

Place this immediately before `auto-compact-if-needed`:

```lisp
(defun count-recent-messages-for-window (session window)
  "Return how many trailing messages to preserve verbatim during
auto-compaction. Targets roughly 25% of the context window: walk
backwards from the end of the message list, accumulating token costs,
until reaching 25% of WINDOW. This ensures the post-compaction context
(initial-system + summary + recent-messages) is comfortably under the
limit, since the summary is much smaller than the messages it replaced."
  (let ((target (floor (* window 1/4)))
        (accumulated 0)
        (count 0))
    (loop for message in (reverse (session-messages session))
          while (< accumulated target)
          do (incf accumulated (approximate-token-count
                                 (message-context-characters message)))
             (incf count))
    count))
```

### Step 2d: Insert the call into `run-agent-turn`

The insertion point is inside the `loop for iteration from 1` body in
`run-agent-turn`, **before** the `run-hook-chain :before-request` call.

Current code (approximately line 1023–1026):

```lisp
         (loop for iteration from 1
          do (let* ((ctx (run-hook-chain :before-request
                                          (list :messages (session-messages session)
                                                ;; A denied budget becomes a no-tool final-answer pass.
                                                :tools (unless tool-budget-finalization-p
                                                         (session-tools session)))))
```

Insert the `auto-compact-if-needed` call at the very beginning of the
loop body, before the `let*` binding:

```lisp
         (loop for iteration from 1
          do (progn
               (auto-compact-if-needed session)
               (let* ((ctx (run-hook-chain :before-request
                                           (list :messages (session-messages session)
                                                 ;; A denied budget becomes a no-tool final-answer pass.
                                                 :tools (unless tool-budget-finalization-p
                                                          (session-tools session)))))
```

**Critical detail:** The original `do` clause has the form
`do (let* (...) ...)`. After inserting `auto-compact-if-needed`, the
`do` clause needs a `progn` to wrap both the compaction call and the
existing `let*`. Make sure the `progn` properly closes — count
parentheses carefully. The entire existing loop body (the `let*`,
the `chat-stream` call, the `:after-response` hook, the tool dispatch,
etc.) goes inside this `progn`.

Alternatively (simpler, less risk of paren mismatch), instead of
wrapping in `progn`, insert the call as the first expression inside
the existing `let*` — but `let*` doesn't allow non-binding forms at
the top. The `progn` approach is correct. Be very careful with
parentheses: the `progn` opens before `let*` and must close at the
very end of the loop body, after all the existing `cond`/`when`/`if`
branches.

**Safer alternative:** Instead of wrapping the whole body in `progn`,
put the call in a separate form before the `let*` using implicit
`progn` in the `do` clause. SBCL's `loop` `do` clause accepts multiple
forms:

```lisp
         (loop for iteration from 1
          do (auto-compact-if-needed session)
             (let* ((ctx (run-hook-chain :before-request
                                          (list :messages (session-messages session)
                                                ;; A denied budget becomes a no-tool final-answer pass.
                                                :tools (unless tool-budget-finalization-p
                                                         (session-tools session)))))
```

**This is the preferred approach** — `loop`'s `do` clause already
allows multiple forms (implicit progn). Just add the
`(auto-compact-if-needed session)` call as the first form after `do`,
before the existing `(let* ...)`. No extra `progn` needed.

### Step 2e: Verify the ordering is correct

The call must happen **before** `run-hook-chain :before-request`. This
ensures:
1. Compaction modifies `session-messages` before the hook chain
   snapshots them into the `ctx` plist.
2. The `:before-request` hook sees the already-compacted message list.
3. The `chat-stream` call uses the compacted messages.

The auto-compaction call must **not** be before the `ui-thinking-started`
call (which is outside the loop, around line 1021) — it's fine where it
is, inside the loop body.

### Why `auto-compact-if-needed` never signals

If it signaled an error, the `provider-error` handler wouldn't catch
it (it only wraps `chat-stream`), and the error would propagate out of
`run-agent-turn` — worse than the problem we're solving. The
`handler-case` around `compact-session-history` swallows all errors
and logs them via `ui-system`. The worst case is: compaction is
attempted, fails, the turn continues with full history, and the
provider may reject the request — but that's the pre-existing behavior,
not a regression.

### Acceptance criteria

1. With a session whose provider returns nil for
   `provider-context-window`, `auto-compact-if-needed` is a no-op
   (returns nil, does not call `compact-session-history`).
2. With threshold 0, `auto-compact-if-needed` is a no-op.
3. With threshold 1.0, `auto-compact-if-needed` is a no-op (compaction
   only triggers strictly above 100%, which never happens).
4. When the estimated context exceeds the threshold, compaction occurs
   and the session's messages are reduced (fewer messages, lower token
   count).
5. The function returns `t` when compaction occurred, `nil` otherwise.
6. If `compact-session-history` signals an error, `auto-compact-if-needed`
   catches it, logs a message, and returns `nil` — does not propagate.
7. The `:before-request` hook chain sees the compacted message list (it
   runs after `auto-compact-if-needed`).

---

## Summary Checklist: All Files Modified

| File | Changes |
|---|---|
| `src/providers/provider.lisp` | Add `provider-context-window` generic + nil default method. Update header comment. |
| `src/providers/openai.lisp` | Add `provider-context-window` override with GPT model alist. |
| `src/providers/anthropic.lisp` | Add `provider-context-window` override with Claude model alist. |
| `src/providers/ollama.lisp` | Add `provider-context-window` override querying `/api/show`. |
| `src/providers/xai.lisp` | Add `provider-context-window` override with Grok model alist. |
| `src/providers/apfel.lisp` | Add `provider-context-window` override returning 4096. |
| `src/providers/reallms.lisp` | **No change** — nil default is correct. |
| `src/config.lisp` | Document `:context-compaction-threshold` key in `load-user-config` docstring. |
| `src/repl.lisp` | Add `context-compaction-threshold` slot to `agent-session`. Add `:context-compaction-threshold` arg to `make-session`. Add `render-messages-transcript` helper. Rewrite `compact-session-history` with `:keep-recent`. Add `estimated-context-tokens`. Add `count-recent-messages-for-window`. Add `auto-compact-if-needed`. Insert `auto-compact-if-needed` call in `run-agent-turn` loop body. Optionally refactor `session-history-transcript` to delegate to `render-messages-transcript`. |
| `src/main.lisp` | Pass `:context-compaction-threshold` from config to `make-session` in `cli-handler`. |

---

## Tests

Add tests to the existing test files. Follow the patterns already
established: `deftest`, `check`, `check-equal`, `check-condition`.
Tests use the `cl-agent` package (see `t/framework.lisp`).

### File: `t/test-providers.lisp` — Provider context-window tests

Add these tests at the end of the file:

```lisp
(deftest provider-context-window-default-is-nil ()
  (check-equal (provider-context-window (make-instance 'llm-provider)) nil))

(deftest provider-context-window-openai-known-models ()
  (check-equal (provider-context-window (make-provider :openai :model "gpt-4o" :api-key "x")) 128000)
  (check-equal (provider-context-window (make-provider :openai :model "gpt-4o-mini" :api-key "x")) 128000)
  (check-equal (provider-context-window (make-provider :openai :model "gpt-4.1" :api-key "x")) 1047576))

(deftest provider-context-window-openai-unknown-model-returns-nil ()
  (check-equal (provider-context-window (make-provider :openai :model "future-model" :api-key "x")) nil))

(deftest provider-context-window-anthropic-known-models ()
  (check-equal (provider-context-window (make-provider :anthropic :api-key "x")) 200000)
  (check-equal (provider-context-window (make-provider :anthropic :api-key "x" :model "claude-3-5-sonnet")) 200000))

(deftest provider-context-window-xai-known-models ()
  (check-equal (provider-context-window (make-provider :xai :api-key "x" :model "grok-4-fast")) 256000))

(deftest provider-context-window-reallms-is-nil ()
  (check-equal (provider-context-window (make-provider :reallms :api-key "x")) nil))

(deftest provider-context-window-apfel-returns-fixed ()
  (check-equal (provider-context-window (make-instance 'apfel-provider)) 4096))
```

### File: `t/test-repl.lisp` — Compaction and auto-compact tests

Add these tests at the end of the file:

```lisp
;;; --- sliding-window compaction ---

(deftest render-messages-transcript-formats-roles-and-content ()
  (let ((text (render-messages-transcript
               (list (list :role "user" :content "hello")
                     (list :role "assistant" :content "hi there"
                           :tool-calls (list (list :id "c1" :name "shell"
                                                    :arguments (jobj "command" "ls"))))))))
    (check (search "USER: hello" text))
    (check (search "ASSISTANT: hi there" text))
    (check (search "ASSISTANT TOOL CALL: shell" text))))

(deftest compact-session-history-keep-recent-zero-compacts-everything ()
  ;; Mock session-complete to return a canned summary.
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (orig (symbol-function 'session-complete)))
    (setf (session-messages session)
          (append (session-messages session)
                  (list (list :role "user" :content "question")
                        (list :role "assistant" :content "answer"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored) (declare (ignore ignored)) "Summary of conversation."))
           (multiple-value-bind (compacted-p before after)
               (compact-session-history session)
             (declare (ignore before after))
             (check compact-p)
             (check-equal (length (session-messages session)) 2)
             (check-equal (getf (first (session-messages session)) :role) "system")
             (check-equal (getf (second (session-messages session)) :role) "system")))
      (setf (symbol-function 'session-complete) orig))))

(deftest compact-session-history-keep-recent-preserves-tail ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (orig (symbol-function 'session-complete))
         (summary-received nil))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i from 1 to 8
                        collect (list :role (if (evenp i) "assistant" "user")
                                      :content (format nil "message ~d" i)))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (prompt &rest ignored)
                   (declare (ignore ignored))
                   (setf summary-received prompt)
                   "Summary of older messages."))
           (multiple-value-bind (compacted-p before after)
               (compact-session-history session :keep-recent 4)
             (declare (ignore before))
             (check compact-p)
             (check-equal (length (session-messages session)) 6 "initial-system + summary + 4 recent")
             (check-equal (getf (first (session-messages session)) :role) "system")
             (check-equal (getf (second (session-messages session)) :role) "system" "the summary")
             ;; The last 4 messages are preserved verbatim:
             (check-equal (getf (sixth (session-messages session)) :content) "message 8")
             (check-equal (getf (fifth (session-messages session)) :content) "message 7")
             (check (> before after "after compaction should be smaller — well, after is smaller only if summary is shorter than older messages; check at least that it ran")))
           ;; The summarizer should NOT have received the recent messages:
           (check (not (search "message 8" summary-received))
                  "recent messages must not be in the summarization transcript")
           (check (search "message 1" summary-received)
                  "older messages must be in the summarization transcript"))
      (setf (symbol-function 'session-complete) orig))))

(deftest compact-session-history-keep-recent-too-large-noops ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (orig (symbol-function 'session-complete))
         (complete-called nil))
    (setf (session-messages session)
          (append (session-messages session)
                  (list (list :role "user" :content "only one"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   (setf complete-called t)
                   "should not be called"))
           (multiple-value-bind (compacted-p before after)
               (compact-session-history session :keep-recent 10)
             (declare (ignore before after))
             (check (not compacted-p) "nothing to compact when keep-recent >= message count")
             (check (not complete-called) "session-complete must not be called")))
      (setf (symbol-function 'session-complete) orig))))

;;; --- auto-compact-if-needed ---

(defclass test-fixed-window-provider (ollama-provider) ())
(defmethod provider-context-window ((provider test-fixed-window-provider)) 1000)

(deftest auto-compact-if-needed-noop-when-window-unknown ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (orig (symbol-function 'compact-session-history)))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i from 1 to 50
                        collect (list :role "user" :content (format nil "padding message ~d with text" i)))))
    (unwind-protect
         (progn
           (setf (symbol-function 'compact-session-history)
                 (lambda (&rest args) (declare (ignore args)) (error "must not be called")))
           (check-equal (auto-compact-if-needed session) nil))
      (setf (symbol-function 'compact-session-history) orig))))

(deftest auto-compact-if-needed-noop-when-threshold-zero ()
  (let* ((session (make-session (make-instance 'test-fixed-window-provider)
                                :context-compaction-threshold 0.0))
         (orig (symbol-function 'compact-session-history)))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i from 1 to 100
                        collect (list :role "user" :content (format nil "padding ~d" i)))))
    (unwind-protect
         (progn
           (setf (symbol-function 'compact-session-history)
                 (lambda (&rest args) (declare (ignore args)) (error "must not be called")))
           (check-equal (auto-compact-if-needed session) nil))
      (setf (symbol-function 'compact-session-history) orig))))

(deftest auto-compact-if-needed-triggers-when-over-threshold ()
  (let* ((session (make-session (make-instance 'test-fixed-window-provider)
                                :context-compaction-threshold 0.1))
         (orig (symbol-function 'session-complete))
         (compacted-p nil))
    ;; Fill with enough messages to exceed 100 tokens (10% of 1000).
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i from 1 to 20
                        collect (list :role "user" :content (format nil "padding message number ~d with enough text" i)))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored) (declare (ignore ignored)) "Compacted summary."))
           (setf compacted-p (auto-compact-if-needed session)))
      (setf (symbol-function 'session-complete) orig))
    (check compacted-p "compaction should have triggered")
    (check (< (length (session-messages session)) 21 "messages should have been reduced"))))

(deftest auto-compact-if-needed-swallows-compaction-errors ()
  (let* ((session (make-session (make-instance 'test-fixed-window-provider)
                                :context-compaction-threshold 0.1))
         (orig (symbol-function 'compact-session-history))
         (output (make-string-output-stream)))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i from 1 to 20
                        collect (list :role "user" :content (format nil "padding ~d" i)))))
    (unwind-protect
         (progn
           (setf (symbol-function 'compact-session-history)
                 (lambda (&rest args) (declare (ignore args)) (error "simulated failure")))
           (let ((*standard-output* output))
             (check-equal (auto-compact-if-needed session) nil))
           (check (search "failed" (get-output-stream-string output))
                  "failure should be logged via ui-system"))
      (setf (symbol-function 'compact-session-history) orig))))

(deftest estimated-context-tokens-matches-session-context-report ()
  (let* ((session (make-session (make-instance 'ollama-provider)
                                :tools (list (find-tool "shell"))))
         (report (session-context-report session))
         (estimated (estimated-context-tokens session)))
    ;; Both should agree on the total token count (they use the same
    ;; computation, just extracted into a reusable function).
    (check (> estimated 0 "tool schemas contribute tokens"))
    ;; The report contains "total:     NNN tokens" — verify they match.
    (check (search (format nil "total:        ~6d tokens" estimated) report))))
```

### File: `t/test-config.lisp` — Config key test

Add at the end of the file (check the existing tests there for the
pattern of writing a temp config file):

```lisp
(deftest config-reads-context-compaction-threshold ()
  (let ((config '(:provider :ollama :context-compaction-threshold 0.5)))
    (check-equal (config-value config :context-compaction-threshold) 0.5)))

(deftest config-context-compaction-threshold-defaults-via-config-value ()
  (let ((config '(:provider :ollama)))
    (check-equal (config-value config :context-compaction-threshold 0.8) 0.8)))
```

### Acceptance criteria for tests

1. All new tests pass when running `make test`.
2. All existing tests still pass (no regressions).
3. The mock pattern for `session-complete` (binding
   `cl-agent::session-complete` via `symbol-function`) matches the
   pattern used in existing tests in `t/test-repl.lisp`.
4. The `test-fixed-window-provider` class subclasses `ollama-provider`
   (which has all the infrastructure) but overrides
   `provider-context-window` to return a small fixed value (1000),
   making it possible to trigger compaction without hundreds of
   messages.

---

## Edge Cases and Guardrails

### 1. Repeated compaction in a single turn

If the turn loop runs many iterations (many tool calls), compaction
might trigger more than once. This is acceptable and correct — each
trigger reduces the oldest history. However, after compaction, the
preserved recent messages might still grow. The `keep-recent` heuristic
(`count-recent-messages-for-window`) targets 25% of the window, so
there's headroom. If somehow the context is still over the threshold
after compaction (summary + recent messages exceed the limit), the next
iteration will try again, this time keeping fewer recent messages
(because the total is smaller). This converges.

### 2. Compaction during the Lisp review revision flow

The `run-agent-turn` loop has a Lisp-code-review revision flow that
appends review findings and re-requests. The `auto-compact-if-needed`
call at the top of the loop body handles this naturally — it runs before
every iteration, whether it's a normal tool-call iteration or a revision
iteration. The revision messages are recent and will be preserved by
`keep-recent`.

### 3. Compaction and the `:before-request` hook

The `:before-request` hook chain can modify messages (that's its
purpose — it receives and returns `(:messages ... :tools ...)`). Since
`auto-compact-if-needed` runs *before* the hook chain, the hooks see
the already-compacted message list. If a hook adds messages (like the
memory extension's digest injection), those additions happen after
compaction and won't be compacted away. This is correct.

### 4. Subagent sessions

Subagents (via `run-subagent`) create their own sessions with
`make-session`. They inherit `context-compaction-threshold` from the
default (0.8) unless explicitly overridden. Auto-compaction will work
in subagent sessions too — they also go through `run-agent-turn`. This
is desirable: long investigation subagents benefit from compaction.

### 5. The `/context` display

After implementing `provider-context-window`, update
`session-context-report` (line 609) to show the capacity percentage
when the provider advertises a window. Currently it prints:

```
Context-window capacity: not advertised by the active provider/model, so no percentage is shown.
```

Change this to:

```lisp
(let ((window (provider-context-window (session-provider session))))
  (if window
      (format nil "Context-window capacity: ~d tokens (~d% used)."
              window (floor (* 100 (/ total window))))
      "Context-window capacity: not advertised by the active provider/model, so no percentage is shown."))
```

This is a **nice-to-have**, not strictly required by the proposal, but
it makes the feature visible to users and is a natural consequence of
Piece 1. Include it for completeness.

### 6. `ui-context-compacted` for auto-compaction

The existing `ui-context-compacted` generic (in `src/ui/frontend.lisp`)
takes `(frontend summary before-tokens after-tokens)`. The
`auto-compact-if-needed` function uses `ui-system` for its notification
instead, because the summary text is embedded in the session messages
(not returned separately). This is fine — `ui-system` is for
informational messages, and auto-compaction is informational. If a
richer UI notification is desired later, a new `ui-auto-compacted`
generic could be added, but that's out of scope for this proposal.

---

## Final Verification Procedure

After all changes are made, perform these checks:

1. **Load the system:** `(load-asdf-system :cl-agent)` succeeds with no
   errors or serious warnings.

2. **Run the full test suite:** `make test` passes with zero failures.

3. **Manual smoke test (requires a provider with known window):**
   - Start cl-agent with `:openai` or `:anthropic`.
   - Have a long conversation (or paste a large block of text repeatedly).
   - Run `/context` — it should now show the capacity and percentage.
   - Continue until auto-compaction triggers — look for the
     `[context] Auto-compacted:` system message.
   - Run `/context` again — token count should be lower.
   - The conversation should continue normally after compaction.

4. **Backward compatibility check:**
   - Start cl-agent with `:reallms` (nil context window).
   - Have a long conversation.
   - No auto-compaction should trigger (no `[context]` messages).
   - `/compact` still works manually as before.
   - `/context` still shows "not advertised" message.

5. **Review-lisp check:** Run `review-lisp` on the modified files. The
   only acceptable advisory is the standard `in-package :cl-agent`
   keyword-package note. No new code-smell findings.
