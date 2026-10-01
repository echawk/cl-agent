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

## Requirements

- [SBCL](https://www.sbcl.org/) and [ocicl](https://github.com/ocicl/ocicl)
  (`./check-env.sh` checks for both). Dependencies -- `drakma` (HTTP),
  `shasht` (JSON), `clingon` (CLI parsing), `cl-mcp`/`cl-mcp/client`
  (MCP client+server), `tuition` (TUI), `hunchentoot` (web UI),
  `bordeaux-threads` -- are pinned in the committed `ocicl.csv`; `make
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
- **`write-extension`** writes a named `.lisp` file to
  `~/.config/cl-agent/extensions/`, loads it into the running image
  immediately, and (by default) enables it to auto-load on every
  future start.

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

See `src/extensions.lisp` and `src/hooks.lisp` for the full design --
both are written with the expectation that an LLM, not just a human,
is the one reading them and writing new code against them.

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

`eval-lisp` also checks submitted code for balanced parentheses before
evaluating it (and `write-extension` before writing a file), reporting
specifically how many are unclosed and roughly where, rather than a
bare reader end-of-file error -- a small, self-contained utility
(`check-paren-balance` in `src/extensions.lisp`), not a dependency,
since nothing freely available did exactly this.

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

**Extending it**: a UI frontend is a CLOS class (`AGENT-FRONTEND`)
implementing a handful of generic functions -- show the model's reply,
show a tool call starting/finishing, show a system notice, and block
for the next line of input -- registered with `register-frontend-
class` exactly the way a new LLM provider is registered with
`register-provider-class` (see [Providers](#providers)). Nothing about
`src/repl.lisp` knows or cares whether it's talking to a terminal, a
browser, or something else -- a user (or the agent itself, via
`write-extension`) can write a new frontend -- an SDL window, a Discord
bot, a true multi-user hosted chat -- as a `src/ui/*.lisp`-sized file,
without touching the conversation loop. See `src/ui/frontend.lisp`'s
header comment for the exact contract and `src/ui/tui.lisp`/`web.lisp`
for two real (not toy) examples of implementing it, including the
threading involved in keeping a blocking LLM call from freezing a
redraw loop or an HTTP server.

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
