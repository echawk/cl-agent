# cl-agent

A small command-line coding agent, written in Common Lisp, with one
unusual feature: because Common Lisp is image-based, **the agent can
extend and modify its own running process**, and persist those changes
across restarts, from inside a normal conversation. See
[Self-modification](#self-modification) below. It can also check its
own Lisp against the actual ANSI standard rather than guessing -- see
[Looking up the Common Lisp standard](#looking-up-the-common-lisp-standard).

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
  (`./check-env.sh` checks for both). Dependencies (`drakma` for HTTP,
  `shasht` for JSON) are pinned in the committed `ocicl.csv`; `make
  install-deps` (or plain `ocicl install`) fetches them.
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
| `apple` | Apple on-device models | a bridge executable, see `src/providers/apple.lisp` |

Pick one with `--provider NAME`, the `CL_AGENT_PROVIDER` environment
variable, or `:provider` in `~/.config/cl-agent/config.lisp` (CLI >
env > config > default `reallms`; see `src/main.lisp`). `--model NAME`
overrides the provider's default model the same way.

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

## Configuration

`~/.config/cl-agent/config.lisp` (copy `config/config.lisp.example` to
start) is a plain data file -- read, never evaluated -- for
`:provider`, `:model`, `:api-key-env`, `:base-url`, `:system-prompt`,
`:extensions`, and `:max-tool-iterations`. See `src/config.lisp` for
the full list. `--config-dir PATH` points the whole thing (config
*and* extensions) somewhere other than `~/.config/cl-agent/`.

## Development

```sh
make test          # offline unit test suite (no network, no provider needed)
make test-ollama   # pulls a small model and runs a live end-to-end test
make run           # run from source, no build step
make clean         # remove the ocicl package cache and bin/
```

`make test` runs `t/test-*.lisp` (JSON encoding, hooks, tools,
provider request/response shaping for both wire formats, config
loading, the extension loader, the REPL's slash commands, and the
`lookup-cl-spec` tool against the real committed spec data) -- all
pure/offline, so they don't need a provider or network access.
`make test-ollama` is the one
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
