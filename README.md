# cl-agent

A small command-line coding agent, written in Common Lisp, with one
unusual feature: because Common Lisp is image-based, **the agent can
extend and modify its own running process**, and persist those changes
across restarts, from inside a normal conversation. See
[Self-modification](#self-modification) below. It can also check its
own Lisp against the actual ANSI standard rather than guessing (see
[Looking up the Common Lisp standard](#looking-up-the-common-lisp-standard)),
reach out to (and be reached by) other tools over
[MCP](#mcp-model-context-protocol), and run as a plain terminal
session, a full-screen TUI, or a browser chat page -- see
[User interfaces](#user-interfaces) -- all three driving the exact
same agent core.

It satisfies the brief it grew out of (see `task.txt`): a tool for
running shell commands, a chat REPL, and an LLM backend -- but it is
built so that backend is swappable. [REALLMS](https://servicenow.iu.edu/kb?id=kb_article_view&sysparm_article=KB0027272)
(Indiana University's gateway) is the default, but OpenAI, Anthropic,
xAI/Grok, a local Ollama server, and (with a small bridge executable)
Apple's on-device models are all one `--provider` flag away. See
[Providers](#providers).

## Quick start

```sh
make build              # produces bin/cl-agent
export REALLMS_API_KEY=...   # or see Providers, below, for alternatives
./bin/cl-agent "list the files in this directory"
```

or, without building a standalone image:

```sh
make run ARGS='"list the files in this directory"'
```

The built image carries its own Lisp source. `make build` copies every loaded
system's `.lisp` and `.asd` files into the image as it is saved: cl-agent's
and every library's (Lem, slynk, hunchentoot …), about 23 MB. So the Lisp
tab's `M-.` and the agent's `lisp-source` tool can show any definition's
source even where the tree is absent or has changed since. When the copy on
disk is the one that was compiled, `M-.` reads it from disk.
`CL_AGENT_EMBED_SOURCES=own make build` keeps only cl-agent's own (about
1 MB), and `=none` keeps none.

Run with no initial task to drop straight into the REPL (`/help` lists
commands, Ctrl-D exits):

```
$ ./bin/cl-agent
cl-agent -- REALLMS (Qwen3-Coder-Next)
Type /help for commands, Ctrl-D to exit.
> what files are in this directory?
```

### Session snapshots

The REPL can save named local conversation snapshots under
`~/.config/cl-agent/sessions/`:

```text
/session save before-refactor
/session list
/session restore before-refactor
```

`/session save` without a name generates a timestamped name. A snapshot restores
the normalized conversation history, current model, compatible active tools,
orchestration mode, and usage counters; it deliberately retains the current
frontend, provider implementation, and credentials.

### Component reflection

`/components` lists the active tools, providers, frontends, hook points,
commands, skills, and MCP connections from one common catalog. Use
`/components tool` to filter by kind or `/components tool:read-file` to inspect
one component's origin, owner, version, dependencies, and declared effects.
The model can use the read-only `list-components` and `describe-component`
tools for the same information.

### Sandboxed execution and debugging

Two Autolith-compatible libraries are included and pinned through OCICL:
[`cl-exec-sandbox`](https://github.com/lambda-symbolics/cl-exec-sandbox) and
[`daphne`](https://github.com/lambda-symbolics/daphne). The model-facing
`sandbox-shell` tool executes one bounded command under a workspace-write
policy: it has isolated network access, can write only the current workspace,
and preserves agent/repository metadata. The established `shell` tool remains
available for managed background jobs while execution policy work continues.

`connect-dap-adapter`, `list-dap-adapters`, and `disconnect-dap-adapter` own
the lifecycle of Debug Adapter Protocol servers through Daphne. Each live
adapter is published in the component catalog as `dap-connection:NAME`, with
its command and current session state visible through `/components`. The
initial integration intentionally provides connection management rather than
pretending to offer a complete breakpoint/stack-frame debugger interface; DAP
request-level tools can build on the owned session next.

## Requirements

- [SBCL](https://www.sbcl.org/) and [ocicl](https://github.com/ocicl/ocicl)
  (`./check-env.sh` checks for both). Dependencies -- `drakma` (HTTP),
  `shasht` (JSON), `clingon` (CLI parsing), `cl-mcp`/`cl-mcp/client`
  (MCP client+server), `tuition` (TUI), `hunchentoot` (web UI),
  `bordeaux-threads`, `3bmd` (Markdown rendering), `cl-exec-sandbox`
  (policy-enforced command execution), and `daphne` (DAP client) -- are pinned in the committed `ocicl.csv`; `make
  install-deps` (or plain `ocicl install`) fetches them. One of
  `cl-mcp`'s own dependencies, `opsis/conditions`, isn't published
  anywhere ocicl/Quicklisp can fetch it from; `third-party/opsis-
  conditions-stub/` is a small committed compatible stand-in -- see
  that file's header comment.
  - **slt** (the Terminal tab) is a git submodule in `third-party/slt`;
    `make install-deps` fetches it.
  - Builds and tests run SBCL with `--no-userinit`, so a dependency
    missing from `ocicl.csv` fails the build. It is not found quietly
    through `~/.sbclrc` (nyaml, which `cl-skills` needs, was found that
    way until it was pinned).
  - **Updating:** `scripts/update-deps.sh` moves slt to its upstream head
    (`slt REF` for another commit), `ocicl [SYSTEM...]` takes ocicl's
    latest, and `all` does both. It lists upstream's new commits, flags
    those touching what cl-agent uses, and then runs
    `scripts/check-deps.lisp`. That script checks that everything loads
    from inside the project, and that the slt internals and client API
    cl-agent calls still exist. Add `--test` to run `make test` too.
    Nothing is committed for you.
- An API key for whichever provider you use (not needed for Ollama).
- Optionally, [Ollama](https://ollama.com) running locally, for
  `make test-ollama` and the `:ollama` provider.

## Providers

| `--provider` | Backend | Needs |
|---|---|---|
| `reallms` (default) | IU's REALLMS gateway | `REALLMS_API_KEY` |
| `openai` | OpenAI | `OPENAI_API_KEY` |
| `anthropic` | Anthropic Claude | `ANTHROPIC_API_KEY` |
| `xai` | xAI / Grok | `XAI_API_KEY` |
| `ollama` | a local Ollama server | nothing (local, no key) |
| `apple` (same as `apfel`) | Apple Intelligence on-device, via [apfel](https://apfel.franzai.com) (`brew install apfel`) | nothing (local, no key; macOS 26+, Apple Silicon, Apple Intelligence enabled) |

Pick one with `--provider NAME`, the `CL_AGENT_PROVIDER` environment
variable, or `:provider` in `~/.config/cl-agent/config.lisp` (CLI >
env > config > default `reallms`; see `src/main.lisp`). `--model NAME`
overrides the provider's default model the same way.

`ollama` and `apple`/`apfel` both start their own backing local server
automatically if it isn't already running (`ollama serve` / `apfel
--serve`, respectively -- see PROVIDER-ENSURE-READY in
`src/providers/provider.lisp` and the two providers' own files) --
picking either of those as your provider is meant to just work, not
require a separate manual step first. apfel's context window is small
(4096-8192 tokens, input+output combined, depending on macOS version)
and its tool-calling is occasionally flaky, the same caveats Ollama's
own tiny local models have -- see `src/providers/apfel.lisp`'s header
comment.

If neither `--model` nor `:model` in config is set, cl-agent calls the
selected provider's `/models` endpoint at startup and presents the live list
for a one-time selection. Press Enter to retain the provider default. The
agent can inspect the same list later with its `list-models` tool. In an
interactive session, `/model` lists those IDs and `/model ID` (or `/model N`)
switches the session to a listed model.

Set `:orchestration-mode :plan` in config, or run `/mode plan`, to prepare
each user task with an independent, tool-free planning call. The visible
intermediate brief gives the main agent a rewritten task, a short plan,
suggested registered tools, and verification criteria. `/mode direct` returns
to the normal loop. In plan mode only validated suggested tools and
`discover-tools` initially reach the main agent; `discover-tools` searches the
full session catalog and enables a small matching set for the next request.
Set `:orchestration-tool-limit` (default `8`) to cap the number of schemas
available in plan mode; discovery respects the remaining budget.
This is a context-window safeguard, not a cap on work: tool-call execution
rounds default to `1000` (`:max-tool-iterations`), including plan-mode work
and unprofiled subagents. Set that key lower in config when a deployment needs
a stricter cost or time bound.

`/mode plan-review` adds a final, tool-free verification stage. It receives the
task evidence and proposed answer, then accepts it, requests one bounded
evidence-focused revision, or visibly blocks an unverified completion.

Every model-proposed `shell` call also receives an isolated, tool-free command
inspection pass. It checks the command against the user task and accumulated
evidence for necessity, scope, and technical sense; a rejected command is not
run, and the agent receives a concise reason plus a safer next step. This is a
sanity check, not a permission prompt. Task inputs, plans, tool receipts, and
terminal state are recorded under `~/.config/cl-agent/tasks/` for later
orchestration stages.

**On tool-calling reliability with small local Ollama models**: cl-agent's
default system prompt and tool set (7 tools) are correctly sent and
correctly parsed regardless of model size -- verified directly against
Ollama's raw API with and without cl-agent in between. What varies is
whether the *model* reliably chooses to call a tool instead of just
describing what it would do (e.g. telling you to run `pwd` yourself
instead of running it). A ~0.5B model frequently fails to call a tool
at all once there's a realistic system prompt and several tool schemas
in context; a 7B-class model (e.g. `ollama pull qwen2.5:7b`, then
`--model qwen2.5:7b`) is dramatically more reliable at actually
invoking tools, including chaining a retry after a failed shell
command. Use `OLLAMA_TEST_MODEL` (see the Makefile) to point the test
suite at a specific pulled model; the tiny default there is chosen for
CI speed, not as a recommendation for interactive use.

None of this is hard-wired: `src/providers/provider.lisp` defines the
five-function protocol every provider implements, `src/providers/
openai-compatible.lisp` is the shared base for the four backends that
speak OpenAI's wire format, and `src/providers/anthropic.lisp` shows
what implementing a genuinely different wire protocol from scratch
looks like. Adding another provider is a new file plus one
`register-provider-class` call -- see those files' header comments,
or just ask the agent to do it for you (next section).

## Self-modification

The agent has two tools, beyond the shell tool, that act on its own
running Lisp image:

- **`eval-lisp`** evaluates a form in the agent's own process right
  now. Ephemeral -- gone on restart. Good for the agent to inspect its
  own state (`(list-tools)`, `(list-hooks)`) or try an idea.
- **`write-scratch-file`** saves an arbitrary, non-executing artifact
  under `~/.config/cl-agent/scratch/`. It is for draft programs,
  one-off test files, and code the user wants to keep; it never loads,
  compiles, or enables the saved text.
- **`write-extension`** writes a named `.lisp` file to
  `~/.config/cl-agent/extensions/`, loads it into the running image
  immediately, and (by default) enables it to auto-load on every
  future start. It only accepts code that integrates a durable agent
  capability (a tool, hook, method, provider, frontend, or slash
  command), so standalone programs cannot accidentally become startup
  extensions.

Because of this, you can ask the agent in plain English to improve
itself, and it can actually do it -- durably:

```
> add a tool that counts words in a string, and a /wc shortcut for it
[agent calls write-extension; the tool and slash command are live
 immediately, and still there next time you start cl-agent]
```

`config/example-extension.lisp` is a worked example (a tool, a hook,
and a slash command, none of which touch the core agent's source);
copy it to `~/.config/cl-agent/extensions/` to try it without needing
a live model. `~/.config/cl-agent/extensions/enabled.lisp` controls
which files load at startup -- new files are enabled by default
(everything loads), but can be selectively disabled (kept on disk,
just not loaded) via `set-extension-enabled`, which `write-extension`
calls for you. `/extensions`, `/reload`, and `/hooks` in the REPL show
what's currently loaded and hooked.

**A hook can give the model its own opinion to act on**, via
`session-complete` (`src/repl.lisp`): run a prompt through the current
session's own provider as an independent completion (its own system
prompt, no effect on the real conversation, but still counted in
`/stats`) and get the reply text back. This is what makes a request
like "rewrite everything you say as a poem," "refuse to save code that
has a code smell," or "formalize whatever I send you before you see
it" actually implementable, not just describable -- at three different
points in the pipeline:

| Hook point | Fires | Use it to |
|---|---|---|
| `:user-message` | Once per incoming user turn, before it becomes a message -- earliest point there is, before the system prompt or any prior turn | Rewrite or expand what the user asked, before the model sees it |
| `:after-response` | After the model's reply, before it's shown | Rewrite the assistant's own reply |
| `:before-tool-call` | Before a tool runs | Judge something and veto the call if it fails |

```
> write me an extension that formalizes my messages before you see
  them, and rewrites every reply you give as a short Dr. Seuss-style
  poem
[agent calls write-extension with a :user-message hook that calls
 session-complete on the incoming text with a "remove slang, keep the
 meaning" system prompt, and an :after-response hook that does the
 same on its own reply with a Seuss-voiced one]

> also add one that works out a plan before acting, and one that
  refuses to save code with an obvious code smell
[a second :user-message hook prepends a synthesized plan -- which
 tool(s) to use and in what order -- ahead of the user's own text,
 using SESSION-TOOLS to know what's actually available; a
 :before-tool-call hook on write-extension calls session-complete to
 judge the code and (error "...") to veto the call if it looks
 smelly -- the file is never written, and the model sees why and can
 revise]
```

A `:before-tool-call` hook function that signals an error vetoes the
call outright: the tool never runs, and the condition's message
becomes what the model is told, the same as any other tool error (see
`run-tool-call` in `src/repl.lisp`). `config/example-llm-roundtrip-
extension.lisp` has all four of the above, worked and tested end to
end -- each gated behind its own `*example-...-enabled*` variable, off
by default, so loading the file doesn't stack every transformation on
top of every message at once.

See `src/extensions.lisp` and `src/hooks.lisp` for the full design --
both are written with the expectation that an LLM, not just a human,
is the one reading them and writing new code against them.

### When the model's code goes wrong

Code the model writes runs inside the agent's own process, so
`src/guard.lisp` keeps the process alive whatever that code does by
mistake:

- **Errors of every kind:** a bad argument, a hash table read with
  `getf`, runaway recursion, or a timeout. The model gets the error back
  as the tool's result.
- **Non-local exits:** `(abort)`, `(continue)`, a restart, a `throw` past
  its caller, or a thread ending another. Each is stopped where it would
  leave the tool call, hook or turn.
- **Exits:** a tool, extension or other thread can't exit the image, and
  can't terminate the agent's own threads.
- **Memory:** past half the heap, the model's code (including threads it
  started) is stopped with a storage error, before SBCL's collector runs
  out of room. That is the one failure no handler could catch.
- **Broken hooks:** a hook that keeps failing is switched off.
- **Removed guards:** anything the code takes away, such as the debugger
  hook or the exit guard, is put back after each call.

What `eval-lisp` prints comes back to the model. The terminal is not
the model's to write to, close or wait on.

These guards stop accidents, not a model set on sabotage. Code running
in the same image can rebind the guards' own variables or call libc's
`exit`.

`make build` gives the binary a 4 GB heap (`HEAP_MB`).

For an explicit one-off second opinion, the built-in `ask-llm` tool sends a
tool-free independent request. It accepts `prompt`, optional `system_prompt`,
and optional `model`; call `list-models` first to obtain exact model IDs. A
chosen model applies only to that independent request, not the main chat.

## Looking up the Common Lisp standard

The `lookup-cl-spec` tool looks up a function, macro, special
operator, variable, constant, or type by name directly in the text of
the ANSI Common Lisp standard -- useful both for you and for the
agent, which is told to prefer it over guessing when it's unsure of an
exact signature (particularly before writing an extension with
`write-extension`: a wrong signature there costs the agent, not just
the user).

```
> /call lookup-cl-spec {"name": "loop"}
```

or just ask in plain English -- "what does the standard say about
`loop`'s `for ... being` clauses?" -- the model will call the tool
itself when it's useful. (`/call` invokes any registered tool directly,
bypassing the model -- good for trying a tool out, or debugging one you
just added with `write-extension`, without spending a request on it.
`/lisp FORM` is the shortcut for `eval-lisp`: `/lisp (list-tools)`
evaluates the form in the agent's own image and prints the result.)

This works entirely offline, against `data/cl-spec.sdoc`, a ~4.6MB
file **committed to this repo** containing the whole spec as plain
s-expressions. It's generated once by
[metaspectre](https://codeberg.org/dlowe/metaspectre), which parses
the draft ANSI standard's TeX sources (bundled in that repo) into that
format; `scripts/build-clspec-data.sh` drives metaspectre to produce
it. Nobody needs to run that script to use `lookup-cl-spec` -- the
output is already committed -- it's there only for regenerating the
data (e.g. to pick up an upstream errata fix) or auditing where it
came from. cl-agent does not depend on metaspectre, or on its own
dependencies (`alexandria`, `cl-ppcre`, and an unpublished templating
library), at runtime: `src/clspec.lisp` just `read`s the committed
data file and renders it to plain text. See that file's header comment
and `scripts/build-clspec-data.sh`'s for the full reasoning.

## Searching loaded Lisp code

`lookup-cl-spec` only covers the ANSI standard. For everything else --
cl-agent's own functions and macros, and every library this image
happens to have loaded -- there's `lisp-apropos`: a name search (via
`apropos-list`) across every loaded package, reporting each match's
kind (function/macro/generic-function/variable/class), lambda list
(via `sb-introspect`), and first line of docstring.

```
> /call lisp-apropos {"query": "flatten"}
ALEXANDRIA:FLATTEN function (TREE) -- Traverses the tree in order, collecting non-null leaves into a list.
SERAPEUM:FLATTEN function (SEQS) -- ...
...
```

This image already has `alexandria`, `serapeum`, `iterate`, and
`trivia` loaded (transitively, via other dependencies -- not something
cl-agent depends on directly, just something already sitting in the
image, same as the standard library). The agent is told to search
before writing a new tool or helper with `write-extension`, so it
reuses an existing function instead of reimplementing one -- and,
separately, to check a cl-agent macro's own real calling convention
(`lisp-apropos("define-tool")`, etc.) before calling it from memory, a
concrete thing a smaller local model gets wrong often enough to be
worth calling out explicitly (see `*default-system-prompt*` in
`src/repl.lisp`). It's a name search, not a type-signature search --
Lisp has nothing like Hoogle for that -- so a query built like a search
phrase (`"reverse words"`) is retried one word at a time if the whole
phrase matches nothing, rather than just coming back empty.

## MCP (Model Context Protocol)

cl-agent is both an MCP **client** and an MCP **server**, via
[cl-mcp](https://github.com/quasi/cl-mcp) (not reimplemented --
src/mcp/*.lisp is a thin adapter over that library's JSON-RPC/stdio
transport, tool registry, and tested client; see those files' header
comments for why it was picked over the alternatives considered,
`cl-mcp-server` and `40ants-mcp`).

**As a client**, connect to any external MCP server and its tools
become ordinary cl-agent tools, namespaced `mcp__NAME__toolname`:

```
> connect to the filesystem MCP server rooted at /tmp
[agent calls connect-mcp-server with name "filesystem" and command
 ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"];
 mcp__filesystem__read_file etc. are now usable tools]
```

or ahead of time via `:mcp-servers` in `config.lisp` (auto-connected
at startup, see [Configuration](#configuration)), or directly with
`/mcp` / `/call connect-mcp-server {...}`. The model has
`connect-mcp-server`/`disconnect-mcp-server`/`list-mcp-servers` as
tools too -- attaching to a new MCP server mid-conversation is a
self-extension act like writing a new tool, so it gets the same
treatment.

Each tool call waits 30 seconds for the server by default. A server that
does slow work takes `:timeout SECONDS`, for example
[REA](https://github.com/morluto/rea), whose Ghidra backend alone may
take minutes to start:

```lisp
:mcp-servers ((:name "rea" :command ("npx" "-y" "rea-agents@6.7.0" "mcp")
               :timeout 600))
```

**As a server**, `cl-agent --mcp-serve` runs as an MCP server over
stdio instead of the chat REPL, exposing every registered tool --
`shell`, `eval-lisp`, `write-extension`, `lookup-cl-spec`, anything an
extension added -- to an external MCP client. This is what gives
cl-agent persistent, tool-rich, self-modifying REPL access from
*outside* itself (the same idea behind `cl-mcp-server`, without
depending on or reimplementing its 37 bespoke tools): point Claude
Code, Claude Desktop, or any other MCP client at
`["/path/to/bin/cl-agent", "--mcp-serve"]` as a server command, and it
can drive this exact running agent.

### Use cl-agent from Codex or Claude Code

Build the executable once, then run the relevant command from this repository
root. `$PWD/bin/cl-agent` becomes an absolute path, so the client can start
the server reliably later.

```sh
make build
```

**Codex CLI.** Add the stdio server and confirm that Codex discovered it:

```sh
codex mcp add cl-agent -- "$PWD/bin/cl-agent" --mcp-serve
codex mcp list
```

The equivalent user-level `~/.codex/config.toml` entry is:

```toml
[mcp_servers.cl_agent]
command = "/absolute/path/to/cl-agent/bin/cl-agent"
args = ["--mcp-serve"]
```

Codex shares this MCP configuration between its CLI and IDE extension. See
the [official Codex MCP setup documentation](https://developers.openai.com/resources/docs-mcp)
for its server-management commands.

**Claude Code.** Add the same local stdio server and inspect its connection:

```sh
claude mcp add --scope user cl-agent -- "$PWD/bin/cl-agent" --mcp-serve
claude mcp list
```

Use `--scope project` instead when the server is intentionally part of a
shared project configuration; then Claude Code writes `.mcp.json` for the
project. Start Claude Code and run `/mcp` to see its connection state. The
[official Claude Code MCP guide](https://docs.anthropic.com/en/docs/claude-code/mcp)
documents scopes, inspection, and removal.

Both commands forward all text after `--` to cl-agent. Add a normal cl-agent
provider option there when needed, for example `--provider apple --mcp-serve`.
The MCP process inherits the client process's working directory, so its file
and workspace tools operate in the project the client opens. Since cl-agent
exports powerful local tools—including shell execution and self-modification—
only register a local checkout and configuration you trust.

`eval-lisp` and `write-extension` run all submitted Lisp through the same
quality gate before executing it: strict [Mallet](https://github.com/fukamachi/mallet)
linting, an explicit type-claim check (DEFSTAR or `declaim ftype`), and an
SBCL compile pass. The result includes a weighted score whose direction is
simple—lower is better. Smells are advisory because occasionally awkward code
is necessary; compiler failures prevent execution/writing and are returned to
the model to fix. The `review-lisp` tool exposes that pipeline directly for
code destined for a normal reply or another file. It accepts any Common Lisp:
- source text, with an optional package for a snippet that has no
  `in-package`;
- a file path;
- `SYSTEM/PATH` as `lisp-source` names it, which reaches the agent's own
  source even when only the built image holds it.

The compile check never changes the running image. The macros, compiler
macros, classes and packages that compiling would define are put back
afterwards. Code whose packages are not loaded is linted and reported as not
compile-checked, rather than as a failed compilation.

**Parentheses are fixed, not counted.** Models indent Lisp well but count
closing parentheses badly, and smaller ones can loop for a long time adding
and removing them. `fix-parens` (a source text or a file) fixes them the way
Parinfer's indent mode does:
- It trusts the indentation: each line's trailing closers are rebuilt so a
  form closes where the next line's indentation says it ends.
- Stray closers in the middle of a line are dropped.
- Only the top-level forms that are actually unbalanced are touched.
- Strings, comments, `#\(` and `|symbols|` never count.

When `check-parens`, `eval-lisp` or `write-extension` finds an imbalance, it
says exactly where, by line and column, and shows the fix. Passing
`fix_parens: true` applies it.

**Property-based tests from declared types.** `property-test` checks a
Lisp function by calling it many times, with arguments generated from its
declared types (`defun*` or `declaim ftype`, the claims the quality gate
asks for). The arguments grow from small to large.
- **What each call must do:** signal no error (except allowed condition
  types), return within a time limit, return values of its declared return
  type, and satisfy the properties you give as lambdas.
- **Failures:** a failure is shrunk to a smallest example and reported with
  the seed that reproduces it.
- **Other types:** `types` overrides the generated types, for a function
  with no declared types or with class arguments.
- **Real calls:** it calls the function for real, so point it at functions
  without side effects.

### Memory

The agent keeps what it learns across sessions with `remember`, `recall` and
`forget`: a confirmed fact, a lesson, your preferences, a project's gotchas.
- **Scopes:** each entry is global or for the project, meaning the git
  repository the working directory is in.
- **No duplicates:** remembering a key it already has updates that entry.
- **In every request:** every model request carries a digest of the memories
  in its system message. They are kept out of the conversation's history,
  and the `memory` setting turns them off.
- **Storage:** entries live under `~/.config/cl-agent/memory/`, written
  atomically under a lock.

### Logic: facts, rules, constraints and order

The `logic` tool is a logic engine (miniKanren, via
[cl-kanren](https://codeberg.org/cage/cl-kanren)) for reasoning the model can
prove instead of guess. Its main uses are impact analysis, the order to do a
refactor in, and checking that the repository stays consistent after each
step. A knowledge base belongs to the project and is kept across sessions.

```lisp
;; index: the source as facts, by tree-sitter
(file "repl.lisp" "commonlisp")  (defines "repl.lisp" "run-agent-turn" "defun" 1961)
(calls "run-repl" "run-agent-turn")  (references F name line)  (imports F target)

;; assert: rules (recursive ones too, even over cycles) and constraints
(<- (affected ?a) (calls ?a "json-encode"))
(<- (affected ?a) (calls ?a ?b) (affected ?b))
(constraint layering "?a (?fa) calls ?b in ui/"
  (calls ?a ?b) (defines ?fa ?a ?k ?l) (prefix ?fa "providers/")
  (defines ?fb ?b ?k2 ?l2) (prefix ?fb "ui/"))

;; query                         ;; check: every constraint's violations
(affected ?f) (defines ?file ?f ?k ?l) (prefix ?file "ui/")
```

- **Goals:** `and`, `or`, `not` (negation as failure), `=`, comparisons, and
  `contains`, `prefix` and `suffix`.
- **Rules** are derived bottom-up to a fixpoint, so recursion always ends.
  Rules that use `not` are evaluated in strata.
- **`order`** puts a dependency relation into layers: change layer 1 first,
  then 2, and so on. A cycle is reported as one group to change together.
- **Your own facts:** the model, or a subagent, can add facts from reading
  code or from `structural-query` (ast-grep) results.
- **Speed:** cl-agent's own `src/` (114 files) indexes in under half a second
  into about 17,000 facts, and a full transitive closure of its calls derives
  in a few seconds.

## ACP (Agent Client Protocol)

`cl-agent --acp-serve` runs an [Agent Client Protocol](https://agentclientprotocol.com/)
peer over stdio through `agentcomms`. Unlike MCP mode, which exposes tools to
another agent, ACP mode exposes complete independent cl-agent conversations to
an ACP-capable editor or client. Each `session/new` receives a fresh provider
instance and cl-agent session; `session/prompt` streams assistant text and
tool/status activity, while `session/cancel`, `session/list`, `session/close`,
and `session/delete` operate on those live sessions.

```sh
./bin/cl-agent --provider ollama --acp-serve
```

ACP uses standard input and output exclusively for JSON-RPC, so diagnostics
are written to standard error and the server never opens the interactive model
picker. `--acp-serve` and `--mcp-serve` are separate modes and cannot be used
together. Session snapshots remain available within each conversation through
the existing `/session` command; durable ACP session restore is intentionally
not advertised yet.

## Language servers and Skills

Language-server support is built on the included
[cl-lsp](https://github.com/lambda-symbolics/cl-lsp) client. Put a bounded
declarative `lsp.sexp` in the selected config directory; cl-agent checks which
configured commands exist at startup, but starts a server only when the agent
uses `lsp-query` or `lsp-diagnostics` on a matching file. The available tools
are `list-lsp-servers`, `lsp-query`, `lsp-diagnostics`, and
`reload-lsp-servers`. Queries are read-only and include definition, references,
hover, implementation, type definition, and document/workspace symbols.

```lisp
(:version 1
 :servers ((:name "clangd" :command "clangd" :arguments ("--background-index")
            :extensions (".c" ".h" ".cpp") :language-id "cpp"
            :root-markers ("compile_commands.json") :timeout-seconds 10)))
```

Skills use [cl-skills](https://github.com/lambda-symbolics/cl-skills) and the
standard `SKILL.md` format. Put a skill in `.agents/skills/<name>/SKILL.md` for
the current project or `~/.config/cl-agent/skills/<name>/SKILL.md` for a
user-wide skill. The model sees only metadata through `list-skills`; it uses
`read-skill` to load the validated instructions only after selecting one.

The `load-asdf-system` tool loads libraries by ASDF system name. `boot.lisp`
installs ocicl's missing-system hook into ASDF, so a missing system is fetched
through ocicl rather than by downloading `.asd` files manually.

While the agent runs, ocicl keeps what it fetches in the config directory,
`~/.config/cl-agent/systems/`, which holds `ocicl.csv` and `ocicl/`. It never
writes to the working directory, so starting `bin/cl-agent` in a repository
never leaves ocicl files there. The tool is the only thing that fetches.
A saved `bin/cl-agent` still finds the systems it was built with, by their
recorded `.asd` paths.

## Emacs integration

`integrations/emacs/cl-agent.el` is a copy-into-your-init.el starting
point (not a MELPA package) giving Emacs users two independent ways to
reach cl-agent, in increasing order of capability:

- **`cl-agent-ask`** -- zero dependencies. Runs `cl-agent-executable`
  on a one-shot task as an async subprocess and streams its output
  live into a `*cl-agent*` buffer, without blocking Emacs.
- **`cl-agent-gptel-mcp-server-entry`** -- full, bidirectional tool
  use from inside [gptel](https://github.com/karthink/gptel)'s chat
  buffers, via the MCP server mode described above. gptel already
  ships an MCP client (`gptel-integrations.el`, bundled with gptel
  itself) that talks to [mcp.el](https://github.com/lizqwerscott/mcp.el)
  (the `mcp-hub` package it expects, not on MELPA -- install it the
  same way you'd install `claude-code-ide.el`, via Emacs 30+'s `:vc`
  package keyword); this function builds the `mcp-hub-servers` entry
  that points it at `cl-agent --mcp-serve`. Once connected
  (`gptel-mcp-connect`), every cl-agent tool -- `shell`, `eval-lisp`,
  `write-extension`, `lookup-cl-spec`, anything a loaded extension
  added -- is callable from a gptel chat, including editing your own
  init.el if you ask it to.

See the file's header comment for the exact setup snippet.

## User interfaces

Three frontends ship, all driving the identical `run-agent-turn`/
`run-repl` conversation loop (`src/repl.lisp`) through one small
protocol (`src/ui/frontend.lisp`) -- proof that the UI is swappable,
not just the LLM backend:

| `--ui` | What it is |
|---|---|
| `cli` (default) | Today's plain terminal session -- unchanged. |
| `tui` | A full-screen terminal UI (scrollable transcript + persistent input box), via [tuition](https://github.com/atgreen/cl-tuition). |
| `web` | A browser workspace, via hunchentoot, at `http://127.0.0.1:4567/` by default: a Lisp-machine-style listener with tab completion, live subagent graphs, and a UI the agent can restyle and extend on request (see [Web UI](#web-ui)). Loopback-only. |

```sh
./bin/cl-agent --ui tui
./bin/cl-agent --ui web   # then open the printed URL
```

**The TUI and web UI both show the model's reply appearing live,
token by token, as it streams in** (not just the final text all at
once), plus a "thinking" indicator while waiting and a running stats
line (provider/model, elapsed time, request count, tool-call count,
token usage where the provider reports it) updated after every turn.
This is real incremental HTTP streaming for any OpenAI-compatible
provider (REALLMS/OpenAI/xAI/Ollama/apfel) -- see `CHAT-STREAM` and
`PARSE-SSE-STREAM` in `src/providers/provider.lisp`/`openai-
compatible.lisp` -- with a plain (non-streamed, but still correct)
fallback for a provider that doesn't implement it (Anthropic, for
now). `/stats` shows the same summary on demand in any frontend,
including the plain CLI, which otherwise looks exactly as it always
has -- streaming and stats are purely additive, not something a
frontend has to opt into to keep working.

**Extending it**: a UI frontend is a CLOS class (`AGENT-FRONTEND`)
implementing a handful of generic functions -- show the model's reply
(in full, or incrementally), show a tool call starting/finishing, show
a stats update, show a system notice, and block for the next line of
input -- registered with `register-frontend-class` exactly the way a
new LLM provider is registered with `register-provider-class` (see
[Providers](#providers)). Nothing about `src/repl.lisp` knows or cares
whether it's talking to a terminal, a browser, or something else -- a
user (or the agent itself, via `write-extension`) can write a new
frontend -- an SDL window, a Discord bot, a true multi-user hosted
chat -- as a `src/ui/*.lisp`-sized file, without touching the
conversation loop. See `src/ui/frontend.lisp`'s header comment for the
exact contract and `src/ui/tui.lisp`/`web.lisp` for two real (not toy)
examples of implementing it, including the threading involved in
keeping a blocking/streaming LLM call from freezing a redraw loop or
an HTTP server.

## Web UI

`--ui web` opens a flat, Lisp-machine-inspired workspace (think Symbolics
Genera and Interlisp-D, in an 80s workstation palette: putty and paper, the
classic six-band rainbow as racing stripes, and a neon-CRT dark mode). It is light by
default. The theme button and `Alt-T` cycle through light, dark and **mono**,
a 1-bit Lisp-machine screen where state is shown by inversion and hatching
instead of colour. `/theme NAME` picks one directly.

- **The layout is yours to change.** The title bar's **Layout** menu
  shows or hides each part of the page: the side panes (`Ctrl-\`), the
  live-session rail, the prompt, the who-line, and the Code tab's file list
  (also its **Files** button).
  - **Zoom** (`Alt-Z`) leaves only the tab in front, edge to edge. Press
    `Alt-Z` again, or **Unzoom**, to bring the rest back.
  - Drag the splitters to resize: side panes against the main pane, the
    Code tab's file list against its editor, and the Lisp tab's scratch
    buffer against its REPL. Double-click a splitter to put it back.
  - A hidden prompt comes back when something is put there (C-c C-a in an
    editor, an Ask button) or when you press `/`.
  - The browser remembers your layout; **Reset the layout** undoes it all.
- **Everything on the screen is an object**, as on a Lisp machine. Each of
  these is a *presentation* of something you can examine:
  - a printed Lisp value;
  - a message label (`(C3)`, `(D3)`, an error);
  - a tool call or a tool;
  - an agent row;
  - a file, a stored or live session, a compiler diagnostic, the model;
  - text you have selected.

  The pointer boxes a presentation and the who-line says what the buttons
  do. **Left** does the obvious thing, which is usually to inspect it.
  **Right** opens its menu of commands: Inspect, Ask the agent about it,
  Copy, and its own commands (Cancel, Open in a tab, Edit in Lem, Call it
  yourself, Evaluate it…). Commands that can't be undone come last.

  The **Inspect** panel shows any object's parts, and the parts are
  presentations too, so you can keep drilling down. ◀ Back returns. From
  the keyboard, Tab to a presentation, press Enter for Left and the Menu
  key or Shift-F10 for Right. `Alt-H` (or `/keys`) inspects the keymap
  itself.
- **One prompt for everything**, as at a Genera listener. The input line reads
  what you type and the prompt says what `Enter` will do before you press it:
  - a **Lisp form** (`(+ 1 2)`, `'sym`, `#'f`, or `,anything`) is evaluated in
    the agent's own image, and its output, values and debugger appear right
    in the listener as `CL-AGENT>` entries. Click a value to inspect it, or
    Alt-click to use it in the next form.
  - **`/name`** runs a command. `/edit @path[:line]` opens a file in the
    Code tab's Lem, and `/mx [command]` runs a Lem command there (`M-x`;
    Tab completes Lem's command names).
    The other way round, `C-c C-a` in Lem (`M-x cl-agent-ask`) puts the
    region, or the Lisp form at point, at this prompt with its file and
    lines, so you can finish the question.
    `/term [dir]` opens a terminal in the Terminal tab, and `/shell [@file]`
    saves a file and runs it there by its type (see
    [The Terminal tab](#the-terminal-tab)).
  - **anything else** goes to the agent as `(C n)`. `Alt-Enter` asks the
    agent even when the text looks like Lisp.

  The rule is "only Lisp forms at the top level": `(optional) fix the tests`
  goes to the agent, and an unfinished form takes `Enter` as a newline.
  Evaluations are ordinary entries in the Lisp tab's REPL, so the agent sees
  them too (`lisp-scratch`). Every button that asks the agent carries its
  mark, a pixel Clippy.

- **Listener**: inputs are numbered `(C n)` and replies `(D n)`, Macsyma-style.
  Replies render as Markdown, with copyable code blocks and MathJax. Each
  turn's tool calls collapse into one `;; 3 tool calls — shell ×2 · read-file`
  line that expands to every call and its output.
- **Tab completion**, served by `src/completion.lisp`: `/commands` (each with
  its docstring), their arguments (`/call shell ` → a JSON skeleton of the
  tool's parameters, `/mode`, `/session restore`, `/settings set`, …), `@paths`,
  and `(lisp-symbols` with their documentation. `↑`/`↓` recall history; `Esc`
  aborts a running turn; messages typed while the agent works are queued.
- **Agents panel**: a process table first, as in Genera's Peek: one row per
  agent, the main one included, with a state word (`RUN`, `WAIT`, `DONE`,
  `FAIL`), elapsed time and what it is doing. Below it are a live
  constellation of subagents and a tree-and-timeline (Gantt) view. Click any
  row or node for details, or to cancel the subagent.
- **Activity, Tools, UI panels**: every tool call with its output, the
  tool catalog (click a tool to `/call` it), and theme, text-size and
  customization controls.
- **Who-line**, as on a Lisp machine: clock, user, the REPL's package,
  provider and model, totals, subagents, and the agent's state. While the
  pointer is over something, the who-line instead says what the mouse would
  do there (Genera's mouse-documentation line, folded into the who-line
  rather than taking a bar of its own).
- **Lisp tab** (`Alt-L`): a SLY-style REPL on the agent's own image, beside
  a scratch buffer the agent shares (see below). There is only one prompt on
  screen at a time, so on this tab the REPL's input *is* the prompt.
  `Alt-Enter` there asks the agent and takes you to the Listener for the
  answer.
- **Pick up where you left off**: when the page finds an empty conversation (a
  fresh start, or cl-agent restarted under an open page), it offers to resume
  your most recent sessions. Resuming runs `/session resume` and replays the
  conversation into the Listener; **Start fresh** dismisses the offer.
- **Model picker**: the title bar's model button (or `Alt-M`, or clicking the
  model in the who-line) lists the provider's models and switches between
  them. Started with `--ui web` and no `:model` configured, cl-agent asks in
  the page rather than in the terminal. **Make it my default** writes
  `:model` into `config.lisp`, keeping your comments.
- **Live sessions**: several agents at once, as vertical tabs down the left
  edge. **+** (`Alt-N`) starts one in a directory of your choice, with its own
  model and name. Each has its own working directory (tools, the editor,
  memory, LSP and environments all use it), conversation, subagents and
  thread, so sessions never wait on each other. A dot means a session is
  working, and a number counts its unread messages. `Alt-↑`/`Alt-↓` switch
  between them, and **×** stops one (its log stays in Sessions). In the
  Sessions view, **Open in a tab** reopens a past session as a live tab, in
  the directory it worked in, with its conversation (nothing in it is run
  again). If the session is already open in a tab, the button goes there
  instead. The first session is the one cl-agent started with. See
  `docs/live-sessions.md`.

### The Lisp tab

A Common Lisp REPL in the browser, on the running agent's image, with what
you would expect from SLY or SLIME:

- **Editing**: syntax highlighting with rainbow parentheses, paren matching,
  and Lisp indentation (`RET`, `Tab` in the indentation).
- **Completion**: `Tab` (or `C-M-i`) completes the way SLY does, using slynk
  itself. It tries each of these in turn:
  - file names inside a string;
  - the keyword arguments of the call at point, from slynk's arglists, so
    `(make-instance 'foo :` offers `foo`'s initargs;
  - symbols and `pkg:` names by prefix;
  - abbreviations such as `m-v-b`;
  - SLY's flex matching, which also searches other packages' exports, so
    `mvbind` and `spl-str` work.

  An open menu narrows as you type, and `M-/` expands a word from the
  buffers, as Emacs's dabbrev does.
- **Echo area**: the argument list of the call at the cursor, with the
  current argument highlighted.
- **REPL**: `RET` evaluates once the input is complete. Output streams in as it
  is printed, `*`, `+` and `/` work, and `in-package` moves the prompt.
  `M-p`/`M-n` (or `↑`/`↓`) recall inputs.
- **Debugger**: an error, `break` or interrupt (`C-c C-c`) opens an SLDB-style
  box with the condition, the backtrace and the real restarts. `USE-VALUE`
  and friends read their value from a box. Number keys pick a restart and
  `q` aborts.
- **Presentations and the inspector**: every printed value is clickable. It
  opens in the **Inspect** side panel, where you can drill into slots,
  elements and hash-table entries. Alt-click puts
  `(lisp-repl-object N)` in the input, to use the object itself.
- **Scratch buffer** (`~/.config/cl-agent/repl/scratch.lisp`, saved as you
  type):
  - `C-c C-c` compiles the toplevel form, `C-M-x` / `C-x C-e` evaluate,
    and `C-c C-k` compiles and loads the whole buffer. Compiler warnings show
    as notes.
  - `M-.` shows a definition's source (and can copy it into the buffer).
  - `C-c C-d d` / `h` / `a` describe, look up in the HyperSpec, and search
    apropos.
  - `C-c RET` / `C-c M-m` macroexpand.
- **Shared with the agent**: "review my scratch buffer" or "why did my REPL
  error?" works because the agent reads both with the `lisp-scratch` tool,
  and edits the buffer with `lisp-scratch-write` when you ask. Its edits show
  up live, a clash with unsaved typing asks which version to keep, and the
  text it replaced is kept in `repl/.history/`. **Ask the agent** buttons on the
  buffer and in the debugger pre-fill the question.
- **In Lem**: the **Lem | Simple** switch on the scratch buffer's title
  edits it in Lem itself, your init file and keys included, with
  `C-c C-c`, `C-x C-e` and `C-c C-k` sending to this tab's REPL. Edits
  save as you type, and the agent's edits show up in Lem. There is one Lem,
  shared with the Code tab: each tab puts its own buffer back in Lem's
  window when you switch to it.

### The Code tab

The Code tab (`Alt-C`) edits your own files through Lem, and holds scratch
buffers in any language.

**The editor is Lem itself.** The hosted Lem is shown by its own web
frontend in the editor pane: its windows, mode line, minibuffer, `M-x`,
dired (`C-x d`), `find-file`, your init file and keys, `vi-mode` if you
enable it. Picking a file in the Files pane, or the agent's
`open-in-editor`, shows it in Lem's window. The **Lem | Simple** switch in
the Code toolbar changes to a lightweight editor that edits the same Lem
buffers (described below), and back. The file you are on goes with you,
and so does one you chose in Lem itself (`C-x C-f`, `C-x b`). The page
follows what Lem shows: the header names the file and marks unsaved
changes, and so does the Open list. Lem's tab bar is off, since the Open
list does its job; `(setf lem/tabbar:*enable-tabbar-on-startup* t)` in your
Lem init file turns it back on.

The agent runs Lem's editing commands too, with the `lem-command` tool:
- **Any command, as `M-x` would run it:** `query-replace`, `indent-region`,
  `comment-region`, `delete-trailing-whitespace` and so on, or a key
  sequence, on a file at a given line or region.
- **Prompts are answered from the answers the agent gives.** A prompt left
  unanswered stops the command and reports what it asked, rather than
  waiting.
- **You see the edits live** in the Lem view, and they stay unsaved unless
  the agent saves.

**Structural edits in any language.** The agent's `syntax-tree` tool edits
code by its tree-sitter syntax tree. It covers C, C++, Python,
JavaScript, TypeScript/TSX, Rust, Go, Ruby, Java, JSON, Bash, CSS, HTML and
Common Lisp.
- **Looking:** `outline` lists a file's functions, classes, methods and keys
  with their lines. `show` prints one node and its parts. `query` runs a
  tree-sitter query.
- **Editing:** `replace`, `delete`, `insert_before` and `insert_after` act
  on a node picked by name (`Circle.area`), by line (plus a kind, such as
  "the function around line 40"), or by query.
- **Refusing breakage:** an edit that would leave the file with more syntax
  errors than before is refused, with the line it would break.
- **Through Lem:** like `lem-command`, edits go through the file's Lem
  buffer, so you see them live, and they stay unsaved unless the agent
  saves.
- **Setup:** it needs tree-sitter's library (`brew install tree-sitter`)
  and a C compiler. Each language's grammar is fetched from its upstream
  repository at a pinned commit and built on first use.
- **One copy of each grammar,** in the config directory's
  `tree-sitter/grammars/`, shared by `syntax-tree` and ast-grep.
  ast-grep's `structural-query` and `structural-rewrite-plan` get
  `tree-sitter/sgconfig.yaml` for the languages ast-grep does not build in,
  so they work on Common Lisp too, as does an ast-grep MCP server pointed
  at that file.

**The copilot.** As you type, a model suggests the code that comes next. It
works in the Lem view and in the simple editor.
- **How it looks:** the suggestion shows faint at the cursor. `Tab` takes
  it, `M-Right` takes its first line, and any other key leaves it.
- **Asking:** a comment saying what to write gets the code that does it.
  `C-c Tab` (`M-x copilot-complete` in Lem) asks at any time. **Copilot on**
  in the editor's toolbar also asks after every pause in typing.
- **Separate from the agent:** it makes its own tool-free requests,
  showing the model only the file around the cursor and nothing of the
  conversation. It uses the session's model unless you pick another in the
  toolbar. The settings `copilot-auto`, `copilot-model` and
  `copilot-delay-ms` keep the choices (`/settings set copilot-model NAME`).
- **Private until taken:** a suggestion is never saved, never in the undo
  history, and never seen by the agent until you take it.

**Files in the simple editor.** `C-x C-f` (find-file) opens a minibuffer
with Lem's file-name completion on `Tab`.
- Enter on a file visits it. It opens with Lem's `find-file-buffer`, so Lem
  picks the mode (from the extension, a `#!` line or a `-*- mode -*-` line),
  and its find-file and mode hooks run, including your init file's.
- Enter on a directory lists it. The Files pane is dired-like: Lem's own
  directory listing, with `n`/`p`, `RET`, `^`, `g`, `R` and `+` as in dired,
  plus new file, new folder, rename and delete.
- While you edit, the text goes into the Lem buffer, not the disk.
- `C-x C-s` saves through Lem's `save-buffer`, so your Lem save settings
  (newline at end of file, trailing whitespace) and save hooks apply. A file
  that changed on disk meanwhile is not overwritten unless you choose to.
- **Revert** reads the file again, and `C-x k` closes it.
- `C-x b` switches buffer, `C-x d` opens dired, and `M-x` lists the commands.

**The working directory** is the one the shell, file and language-server
tools use. Change it with `M-x cd`, **cd here** in the Files pane, `/cd DIR`
in the REPL, or by asking the agent. The title bar shows it, and clicking it
opens the Code tab.

**Scratch buffers.** **New** asks for a name and a language: C, Ruby, Python,
Rust, Go, shell, or any other language Lem has a mode for. Each buffer is a
real file, `~/.config/cl-agent/scratch/NAME.EXT`, saved as you type, so
everything that works on files works on it.

- **Highlighting** comes from Lem's own mode for the language. Lem's core is
  hosted inside cl-agent without a display (`src/lem/`). Fenced code blocks
  in the agent's replies are highlighted the same way, so a ```` ```c ````
  block is coloured as C.
- **Editing** uses the Lisp tab's editor: Emacs keys, `M-/`, and
  `Tab`/`Shift-Tab` to indent. `C-x C-s` saves at once.
- **Completion**: `Tab` (or `C-M-i`) after a word completes the way Lem's
  lsp-mode does. Candidates come from the buffer's language server, sorted
  by its own order, each replacing from where the server says. Its trigger
  characters (`.`, `->`, `::` …) open the menu by themselves; as in the
  Lisp tab, the menu narrows as you type and a sole match goes straight in.
  Without a language server, the buffer's own words complete, nearest
  first. The server starts when the buffer opens, as in Lem.
- **The language server** configured for the extension checks the buffer.
  **Check** (`C-c C-c`) lists its diagnostics (click one to go there), and
  `C-c C-d d` shows its hover text. With no `lsp.sexp`, cl-agent uses
  clangd, pyright, rust-analyzer, gopls, ruby-lsp or
  typescript-language-server, whichever are installed.
- **The agent** lists, reads and edits scratch buffers with the
  `scratch-buffers` and `scratch-buffer-write` tools, and keeps a backup of
  the text it replaced in `scratch/.history/`.
  - For files, `editor-files` shows what you have open, including unsaved
    changes; `read-file` tells it when there are some. `open-in-editor`
    shows you a file at a line, and `set-working-directory` changes the
    working directory.
  - When the agent writes a file you have open, a buffer without unsaved
    changes reloads. One with unsaved changes asks whether to revert or
    keep yours.
  - It asks the same language server through `lsp-diagnostics`. For a file
    you are editing, the server sees the unsaved text.
- **Hooks** let extensions join in. The hook points are:
  - `:working-directory-changed`;
  - `:file-opened`;
  - `:before-file-save`, a chain hook that can rewrite the text (a
    formatter, say) or refuse the save;
  - `:after-file-save`;
  - `:file-written`, for both the editor's and the agent's writes;
  - `:file-closed`.

  Lem's own hooks, from your init file, run as they do in Lem.

The hosted Lem loads your Lem init file, the one Lem itself would load
(`$LEM_HOME`, `~/.lem/`, or `~/.config/lem/`), and then `cl-agent.lisp`
from the same directory, for settings meant only for cl-agent.
`CL_AGENT_LEM_NO_INIT=1` skips both. Code your init file meant only for
Lem's own window can be guarded with `#-cl-agent-lem`.
`docs/lem-integration.md` describes the design, and what remains to do.

Updates are pushed over Server-Sent Events (`/api/events`) against a sequenced
event log, so a reconnecting page catches up without missing or repeating
anything. Mutating requests require an `X-CL-Agent` header and a loopback
`Host`, so other web pages cannot drive the agent through your browser.


### Emacs as the editor

The Code tab's **Lem | Simple | Emacs** switch, and the Lisp tab's scratch
switch, can make Emacs the editor. cl-agent then runs an Emacs daemon of its
own, with your init file, and shows its frames (`emacsclient -t`) in those
panes, drawn by slt like the Terminal tab. Lem stays: it still highlights
code in the conversation and serves the agent's `lem-command`.

What works in Emacs as it does in Lem:
- **Visiting:** a file picked in the Files pane, `/edit`, or the agent's
  `open-in-editor` shows in Emacs's frame. The header follows what Emacs
  shows, and the Open list follows its file buffers and unsaved changes.
- **Commands:** `/mx` runs `M-x` in the frame, and Tab completes Emacs's
  command names. **Find file** and **Buffers** run `find-file` and
  `switch-to-buffer`.
- **Asking:** `C-c C-a` puts the region, or the Lisp form at point, at the
  prompt. It is bound by a global minor mode, so major modes' own `C-c C-a`
  don't hide it.
- **The agent** sees Emacs's open buffers and their unsaved text
  (`editor-files`). It runs Emacs commands with `emacs-command`, its
  prompts answered as with `lem-command`. Its file writes reload buffers
  that have no unsaved changes.
- **The Lisp scratch buffer:** opened in Emacs, it is in Lisp mode with
  `cl-agent-scratch-mode`. `C-c C-c`, `C-x C-e` and `C-c C-k` evaluate in
  cl-agent's image, and it saves itself as you type.
- Emacs's faces follow the page's light or dark theme, and its colours
  come from the page's palette.

The daemon is started the first time a page shows Emacs. It stops with
cl-agent, whichever way cl-agent ends:
- A normal exit stops it with SIGTERM, so Emacs auto-saves.
- If cl-agent is killed or crashes, a watchdog in `src/emacs/cl-agent.el`
  notices Emacs's parent is gone and exits within about a second.
- If Emacs dies first, its panes say so and offer **Reopen**, and the next
  use starts it again. Closing a frame in Emacs (`C-x 5 0`) leaves the same
  note.

cl-agent finds Emacs on `$PATH`, in Homebrew's or MacPorts' bin, or in
`/Applications/Emacs.app`. Set `CL_AGENT_EMACS` and `CL_AGENT_EMACSCLIENT`
to use others. `doctor` reports what it found. How it works, and what is
next (copilot-style completion in Emacs among it), is in
`docs/emacs-integration.md`.

### The Terminal tab

The Terminal tab holds shells next to your files, so you can run programs
and then ask the agent about what they printed. The terminals are
[slt](https://github.com/echawk/slt), a terminal emulator in Common Lisp.
slt runs inside cl-agent's own image with its pure-Lisp `lispvt` engine,
and the tab draws it with slt's own browser client. slt is a git submodule
(`third-party/slt`), pinned to one commit; `make install-deps` fetches it.

- **`/term [dir]`** opens a terminal in DIR, or in the working directory.
  A running terminal already in that directory is shown instead; **+ New**
  always opens another. Each terminal is a tab of its own, and right-click
  gives its menu.
- **`/shell [@file]`** saves a file and runs it in a terminal in its
  directory, by its type. C, C++ and Rust are compiled first; Go, Python,
  Ruby, Racket, JavaScript, Lisp and shell scripts run directly. The
  Code tab's **Run** button and a file's **Run in the terminal** menu
  item do the same.
- **Keys:** in a terminal every key is the program's. Ctrl-C interrupts
  it and Alt is Meta, so the page's own Alt- keys step aside. Two keys
  are not the program's: Ctrl-Shift-A puts the terminal's last lines at
  the prompt, to ask about them (the **Ask** button does the same), and
  Ctrl-Shift-P goes back to the prompt.
- **The agent** reads a terminal with the `terminal-output` tool, and
  never types into it. A shell that exits leaves its last screen behind,
  so you can still ask about it; **Close** hangs up a shell.
- **Images:** Kitty's graphics protocol and SIXEL work. slt decodes PNG
  images with the system's libpng and SIXEL with libsixel (`brew install
  libpng libsixel`, or your system's packages); raw RGB images need
  neither. `doctor` says which are missing.
- Each terminal reaches its shell over a WebSocket on 127.0.0.1. The
  socket needs a random token per terminal and a page on this machine.
### Changing the UI (including by the agent)

The client is a set of plain files in `src/ui/web/static/`: `theme.css`
holds every color and size, and `app.css`, `core.js`, `render.js`,
`composer.js`, `panels.js`, `agents.js`, `views.js`, `menu.js`,
`lisp-editor.js`, `lisp.js`, `code.js` and `main.js` hold the rest. Each
request resolves through three layers: an **override** in
`~/.config/cl-agent/web/`, then an **extension** (registered from Lisp),
then the **built-in** file. Any `patches/*.css` / `patches/*.js` loads
automatically after the core client, with a plugin API on `window.CLAgent`
(`registerPanel`, `registerRenderer`, `registerCommand`,
`registerCompleter`, `on(...)`, …).

Ask the agent for a change ("make the user labels green", "add a panel
showing my git branches") and it uses these tools:

| Tool | Does |
|---|---|
| `web-ui-assets` | Read the guide (`static/EXTENDING.md`), list assets, read one. |
| `web-ui-write-asset` | Write or snippet-edit an override or patch. JS is checked with `node --check`, CSS for balanced braces. |
| `web-ui-reset-asset` | Undo: back to built-in, or one version back. History is kept. |
| `web-ui-command` | Drive open pages now: toast, theme, open a panel or tab, insert text, reload. |

The Lisp tab has two tools of its own: `lisp-scratch` (read the scratch
buffer, or the REPL transcript with its errors and backtraces) and
`lisp-scratch-write` (replace, edit or append to the buffer).

Open pages restyle (CSS) or reload (anything else) as soon as a file changes,
including edits to the repository's own `static/` files. When an edit breaks
the page, `http://127.0.0.1:PORT/safe` serves the built-in files only and
offers **Reset every override**. A page whose overrides keep it from
starting at all, such as an old `core.js` copy missing a newer export, goes
to `/safe` by itself and says why. From the input line, `/ui` lists
customizations, and `/ui reset PATH|all` and `/ui revert PATH` undo them.

For behavior that needs Lisp, extension files (`write-extension`) can use
`define-web-route` (new JSON endpoints), `define-web-patch` (CSS/JS shipped
inside the extension), `web-ui-command` / `web-ui-broadcast` (push to open
pages), `define-command-completer` / `define-completion-source` (completion),
and the `:web-ui-page`, `:web-ui-state` and `:web-ui-asset-changed` hooks.
All of these count as integrations for `write-extension`, and roll back with
a failed mutation. `src/ui/web/static/EXTENDING.md` has worked examples.

## Configuration

`~/.config/cl-agent/config.lisp` (copy `config/config.lisp.example` to
start) is a plain data file -- read, never evaluated -- for
`:provider`, `:model`, `:api-key-env`, `:base-url`, `:system-prompt`,
`:extensions`, `:max-tool-iterations`, `:ui`, and `:mcp-servers`. See
`src/config.lisp` for the full list. `--config-dir PATH` (or the
`CL_AGENT_CONFIG_DIR` environment variable) points the whole thing --
config, extensions and saved state such as sessions -- somewhere other
than `~/.config/cl-agent/`.

## Development

```sh
make test          # offline unit test suite (no network, no provider needed)
make test-ollama   # pulls a small model and runs a live end-to-end test
make test-mcp-external # runs a published npm filesystem MCP server through npx
make run           # run from source, no build step
make clean         # remove the ocicl package cache and bin/
```

`make test` runs `t/test-*.lisp` (JSON encoding, hooks, tools,
provider request/response shaping for both wire formats, config
loading, the extension loader, the REPL's slash commands, the
`lookup-cl-spec` tool against the real committed spec data, MCP client
*and* server against a real subprocess, the web UI frontend
against a real local HTTP server, and tab completion) -- all offline in the sense of no
external network access, though not all mocked: several of those spawn
a real subprocess or open a real (loopback) socket, deliberately,
rather than stub out the thing actually being tested. Every test target
sets `CL_AGENT_CONFIG_DIR` to a fresh temporary directory and removes it
afterwards, so tests never read or write `~/.config/cl-agent/`; the test
runner refuses to run against that directory. `make test-ollama`
is the one
exception: it pulls a tiny model (`qwen2.5:0.5b` by default, override
with `OLLAMA_TEST_MODEL=...`) and exercises the real HTTP + JSON +
tool-calling round trip against it. It isn't run as part of `make
test` because it needs a reachable `ollama serve` and enough free
memory to run even a small model -- both of which are environment-
dependent in a way the rest of the suite deliberately isn't.

Source layout is documented in `src/package.lisp`; most files open
with a comment explaining what they're for and, where relevant, how to
extend them.

## class-ref/

`class-ref/` holds the reference agents (Python, Racket, Rhombus) this
project started from -- same core idea (one shell tool, a chat loop
against REALLMS), much smaller. Useful for comparing approaches.
