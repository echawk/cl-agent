I have direct, conclusive evidence. Both candidate tools live in the same file (src/tools/llm-tool.lisp) and both call the same primitive. Let me lay out the decisive comparison.

The two tool bodies, verbatim from the source:

delegate-task — the general delegation tool:

(RUN-SUBAGENT *CURRENT-SESSION* (JGET ARGS "task") (JGET ARGS "system_prompt")
 (LIST (FIND-TOOL "shell") (FIND-TOOL "lisp-apropos")) :PROFILE (JGET ARGS "profile"))

explore-project — the tool I actually invoked to start this task:

(RUN-SUBAGENT *CURRENT-SESSION*
 (FORMAT NIL "Parent goal: ~a~%~%Parent evidence so far:~%~a" (JGET ARGS "goal")
         (CURRENT-TURN-REVIEW-EVIDENCE *CURRENT-SESSION*))
 "You are a repository explorer working for a host agent. ..."
 (LIST (FIND-TOOL "shell")) :MAX-TOOL-ITERATIONS 8)

Both are thin wrappers over the same run-subagent primitive (defined in src/repl.lisp, sharing the agent-session subagent slots subagent-depth/max-subagent-depth/subagent-model-profiles). That settles the mechanism question. Here is my synthesis.

Result

The feature I'd consider redundant: explore-project.

explore-project and delegate-task are two model-facing tools that both delegate bounded work to an isolated subagent through one shared primitive, run-subagent. explore-project is a specialization of delegate-task: it hardcodes four things that delegate-task accepts as parameters —

The task string — explore-project auto-builds it from the goal plus the parent's accumulated turn evidence (current-turn-review-evidence). With delegate-task, the model constructs the task itself (and it has access to its own evidence, so it can include the same context manually).
The system prompt — explore-project bakes in a fixed "repository explorer" persona; delegate-task takes system_prompt as an argument.
The worker's tool set — explore-project gives the worker shell only; delegate-task gives shell + lisp-apropos.
The iteration cap — explore-project hard-wires :max-tool-iterations 8; delegate-task uses the default.

Why it's redundant: everything explore-project does is fully expressible through delegate-task — the model could call delegate-task with an explorer-flavored system prompt and a task that bundles the parent goal and evidence, and obtain the same behavior. There is no separate code path, no different subagent loop, no distinct model-routing: one primitive, two front doors. explore-project adds no capability that delegate-task lacks; it only pre-fills delegate-task's parameters.

Reason / caveat — why it's defensible redundancy, not pure duplication: explore-project is a curated convenience, the way a named preset wraps a general API. It encodes a proven persona, a sensible reduced tool set (shell-only prevents an over-eager explorer from mutating the image), and a tight iteration budget — steering small models toward a known-good configuration without making them reinvent the prompt each time. So it is redundant in capability but earns its keep as an ergonomic specialization. If one were cutting features for minimalism, explore-project is the one that could be dropped with the least loss, because delegate-task subsumes it; the cost of dropping it would be slightly more prompt-engineering work for the model on repo-structure questions.

Why the other near-overlapping features are orthogonal (not redundant)

For completeness, here are the pairs that look like they might overlap but don't:

ask-llm vs session-complete — layered, not redundant. session-complete is an internal primitive (no tools, no conversation effect) used by the orchestration internals — the planner, the plan-review verifier, the shell-command inspector, and /compact. ask-llm is a model-facing tool that the agent elects to call for a second opinion, and it is literally built on top of session-complete (ask-llm calls (session-complete prompt :system system :model model)). Different callers, different pipeline positions; one is the substrate for the other.

write-extension vs connect-mcp-server — both "add a capability," but by opposite means. write-extension authors and loads Lisp into the running image (durable, self-written code). connect-mcp-server attaches an external process's tools over MCP at runtime (no code authored, third-party binary). Orthogonal.

eval-lisp / write-scratch-file / write-extension — three distinct tiers by persistence and execution: ephemeral eval, non-executing saved draft, durable self-modifying load. None subsumes another.

read-file vs shell — read-file is a bounded, safe accessor for one path; shell runs arbitrary (inspected) commands. read-file exists precisely to avoid routing file reads through the general shell + its inspection pass — a deliberate trust/scope boundary, the same pattern as every other coding agent.

:plan vs :plan-review vs shell-command inspection — three orchestration stages at different points: pre-task planning, post-answer verification, and per-shell-call sanity. They compose; none duplicates another.

lookup-cl-spec vs lisp-apropos — different corpora: the committed ANSI standard text vs. a name search over the live loaded image. Neither covers the other.

discover-tools vs the tool catalog — discover-tools is a plan-mode enabler that grows the exposed tool set within a budget; the catalog is the static inventory. One acts on the other.

So the one feature I'd single out as redundant — redundant in mechanism, retained as a convenience — is explore-project, whose entire behavior is a pre-parameterized call to the same run-subagent that delegate-task already exposes generally.