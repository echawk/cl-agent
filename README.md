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

## Requirements

- [SBCL](https://www.sbcl.org/) and [ocicl](https://github.com/ocicl/ocicl)
  (`./check-env.sh` checks for both). Dependencies -- `drakma` (HTTP),
  `shasht` (JSON), `clingon` (CLI parsing), `cl-mcp`/`cl-mcp/client`
  (MCP client+server), `tuition` (TUI), `hunchentoot` (web UI),
  `bordeaux-threads`, `3bmd` (Markdown rendering) -- are pinned in the committed `ocicl.csv`; `make
  install-deps` (or plain `ocicl install`) fetches them. One of
  `cl-mcp`'s own dependencies, `opsis/conditions`, isn't published
  anywhere ocicl/Quicklisp can fetch it from; `third-party/opsis-
  conditions-stub/` is a small committed compatible stand-in -- see
  that file's header comment.
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
just added with `write-extension`, without spending a request on it.)

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

`eval-lisp` and `write-extension` run all submitted Lisp through the same
quality gate before executing it: strict [Mallet](https://github.com/fukamachi/mallet)
linting, an explicit type-claim check (DEFSTAR or `declaim ftype`), and an
SBCL compile pass. The result includes a weighted score whose direction is
simple—lower is better. Smells are advisory because occasionally awkward code
is necessary; compiler failures prevent execution/writing and are returned to
the model to fix. The `review-lisp` tool exposes that pipeline directly for
code destined for a normal reply or another file.

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
| `web` | A browser chat page, via hunchentoot, at `http://127.0.0.1:4567/` by default -- a proof of concept (polling, not push; one session; loopback-only), not a production web app. |

```sh
./bin/cl-agent --ui tui
./bin/cl-agent --ui web   # then open the printed URL
```

**The TUI and web UI both show the model's reply appearing live,
token by token, as it streams in** (not just the final text all at
once), plus a "thinking" indicator while waiting and a running stats
line (provider/model, elapsed time, request count, tool-call count,
token usage where the provider reports it) updated after every turn.
The web UI renders assistant Markdown (including code blocks and tables),
keeps the reading position fixed unless you are already at the bottom, and
shows a “Jump to latest” control when new activity arrives below you.
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

## Configuration

`~/.config/cl-agent/config.lisp` (copy `config/config.lisp.example` to
start) is a plain data file -- read, never evaluated -- for
`:provider`, `:model`, `:api-key-env`, `:base-url`, `:system-prompt`,
`:extensions`, `:max-tool-iterations`, `:ui`, and `:mcp-servers`. See
`src/config.lisp` for the full list. `--config-dir PATH` points the
whole thing (config *and* extensions) somewhere other than
`~/.config/cl-agent/`.

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
*and* server against a real subprocess, and the web UI frontend
against a real local HTTP server) -- all offline in the sense of no
external network access, though not all mocked: several of those spawn
a real subprocess or open a real (loopback) socket, deliberately,
rather than stub out the thing actually being tested. `make test-ollama`
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
