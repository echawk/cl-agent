# Review: Context-Compaction Implementation Strategy

## Scope

This review evaluates
`context-compaction-proposal-implementation-strategy.md` after implementing
the feature in commit `8e6a2b8` (`feat: add automatic context compaction`).
It is a review of the strategy document as an implementation aid, not a
repeat of the feature proposal.

## Verdict

Yes: the strategy materially made the change easier to implement.  It was
especially effective because it named the protocol boundary, gave a safe
dependency order, identified the exact request-loop insertion point, and
described the backwards-compatibility requirement for `/compact`.

The document was detailed enough to turn a cross-cutting change into a set of
small, independently understandable edits.  That reduced repository
exploration and made it straightforward to distinguish intentional behavior
from incidental existing behavior.

## What went well

### Clear decomposition and ordering

The breakdown into provider protocol, sliding-window history mutation,
configuration, turn-loop integration, provider overrides, and tests was a
good fit for the codebase.  In particular, adding `provider-context-window`
with a NIL base method before changing the REPL meant providers without known
capacity retained their existing behavior.

The stated ordering requirement for `auto-compact-if-needed` -- before the
`:before-request` hook -- was important and correct.  It prevented a subtle
bug where hooks or provider requests could see a stale, pre-compaction message
list.

### Concrete repository guidance

File names, nearby symbols, expected function signatures, and placement
guidance were consistently supplied.  This was useful in a Lisp codebase,
where a small change in a shared generic protocol can otherwise require a
broader search for method implementations and load-order assumptions.

The explicit instruction not to add a REALLMS override was also useful: it
made the intentionally unknown capacity an explicit, safe degraded mode
rather than an omission.

### Preserved user-facing compatibility

The strategy recognized that manual `/compact` and automatic compaction should
not look the same.  Keeping `:keep-recent` at zero by default retained the
manual behavior, while a positive value for automatic compaction preserved a
verbatim recent tail.  The separate summary labels make the resulting session
history introspectable.

### Good operational guardrails

The strategy correctly made automatic compaction advisory and non-fatal:
unknown provider windows do nothing, and compaction failures are reported but
do not abort the agent turn.  That is the appropriate failure mode for a
feature whose purpose is to avoid a request failure rather than introduce a
new hard dependency.

### Testability was considered early

Using a small fixed-window test provider and replacing `session-complete` in
tests is a practical approach.  It avoids live network calls and makes the
threshold behavior reproducible.  The implemented suite passed with 711
passing tests and no failures.

## Where the strategy could improve

### The post-compaction headroom guarantee is not actually guaranteed

The document says the 25%-of-window recent tail creates comfortable headroom
and suggests repeated compaction will converge.  That is not always true.
The initial system prompt, tool schemas, and the mandatory minimum of six
recent messages can themselves exceed the configured threshold.  In that
case, compaction can run successfully yet leave the request above the limit;
repeating it may not improve the result.

This showed up in the small-window test fixture: automatic compaction occurred
but the baseline prompt was already larger than the synthetic 1,000-token
window.  The implementation correctly reports the compaction, but the test
does not demonstrate that the final context is below threshold.

The strategy should instead specify a budget-aware algorithm:

1. Compute the fixed request cost (system messages and tool schemas).
2. Reserve space for a bounded summary.
3. Retain as many recent messages as fit in the remaining budget, allowing
   fewer than six when necessary.
4. If the fixed cost alone exceeds the threshold, do not repeatedly summarize;
   emit a distinct warning that the configured provider window cannot support
   the current baseline.

### The proposed tests contain a concrete typo

In `compact-session-history-keep-recent-zero-compacts-everything`, the example
binds `compacted-p` but checks `compact-p`.  Copying the test verbatim would
fail due to an unbound variable.  The implementation used the correct binding,
but this should be fixed in the strategy.

### Test coverage is presented as more complete than it is

The strategy calls out several critical acceptance criteria, but the proposed
test snippets do not directly verify all of them.  Most notably:

- no test proves the `:before-request` hook observes compacted messages;
- no test establishes that a threshold of `1.0` is a no-op;
- no test asserts the error notification through the actual configured
  frontend rather than a rebound output stream;
- no test verifies the Ollama `/api/show` parser for a normal response,
  missing `num_ctx`, malformed content, and an unreachable server; and
- no test establishes an after-compaction budget invariant.

The strategy should separate a minimum test list from a full acceptance-test
matrix, then require the latter before declaring the feature done.

### Provider-capacity data needs an ownership/update policy

The strategy uses static model-name matching for several remote providers.
That is a sensible hot-path design, but model capacities change and model
aliases proliferate.  The document should name an owner or maintenance rule:
where the source of truth is recorded, how new aliases are added, and whether
unknown newer models intentionally remain manual-compaction-only.

### Contract invariants should be sharper

The protocol says it returns an integer or NIL but does not explicitly require
a positive integer.  The suggested `/context` percentage calculation assumes
a nonzero value.  A third-party provider method returning zero would therefore
cause division by zero.  The contract should require a positive integer or
NIL, and callers should still defensively check `plusp`.

### Validation policy is underspecified

The strategy says the configuration value is a float in `[0, 1]`, but gives no
policy for malformed values.  The implementation chose a safe default of 0.8
for invalid values and accepts any number in the inclusive range.  That is
reasonable, but the strategy should have prescribed it so configuration
behavior is intentional and testable.

## Implementation friction observed

The only direct coding defect encountered was a parenthesis mismatch while
editing the larger `repl.lisp` change.  The strategy anticipated that the
turn-loop edit was structurally risky, although the preferred multi-form LOOP
`DO` form reduced that risk.  Loading and running the test suite caught the
issue promptly.

No design-level conflict was found between the strategy and the existing
architecture.  The provider generic, session slot, config plumbing, and
session-history representation all supported the change cleanly.

## Recommended changes to the strategy document

1. Replace the fixed `max 6` / 25% retention heuristic with an explicit
   post-compaction token-budget calculation and a baseline-overflow warning.
2. Correct `compact-p` to `compacted-p` in the example test.
3. Add an acceptance matrix covering hook ordering, threshold `1.0`, Ollama
   parsing/failure behavior, compaction failure handling, and a final-context
   budget assertion.
4. State that `provider-context-window` must return a positive integer or
   NIL; require defensive validation at call sites.
5. Specify invalid configuration handling and document it alongside the
   threshold key.
6. Add a maintenance note for static provider model-window mappings, including
   their source and update expectations.

## Conclusion

The strategy was a strong implementation guide.  It reduced ambiguity,
preserved compatibility, and directed attention to the two most important
architectural boundaries: provider capabilities and request-loop ordering.
Its principal weakness is treating the retention heuristic as sufficient to
guarantee headroom.  Addressing that budget-model gap and tightening the test
matrix would make the document suitable not only for implementation, but also
for confidently operating the feature across very small windows, large tool
sets, and future providers.
