# Makefile
#
# `ocicl install` (no arguments) reads the committed ocicl.csv lockfile
# and re-populates ./ocicl/ from it -- see boot.lisp and README.md for
# why this project's dependency story is just "run ocicl install".

SBCL ?= sbcl
OLLAMA_TEST_MODEL ?= qwen2.5:0.5b

.PHONY: all check-env install-deps build run test test-ollama test-mcp-external clspec-data clean

all: build

check-env:
	./check-env.sh

install-deps: check-env
	ocicl install

build: install-deps
	$(SBCL) --non-interactive --load boot.lisp --eval '(asdf:make :cl-agent)'

run: install-deps
	$(SBCL) --script run.lisp -- $(ARGS)

test: install-deps
	$(SBCL) --non-interactive --load boot.lisp --eval '(asdf:test-system "cl-agent/tests")'

# Starts `ollama serve` if it isn't already running (same
# PROVIDER-ENSURE-READY logic cl-agent itself uses, see
# providers/ollama.lisp), then pulls a small model so the test has
# something to talk to.
test-ollama: install-deps
	command -v ollama >/dev/null 2>&1 || { echo "ollama not found; install it from https://ollama.com"; exit 1; }
	$(SBCL) --non-interactive --load boot.lisp --eval '(asdf:load-system "cl-agent")' \
		--eval '(cl-agent::provider-ensure-ready (make-instance (quote cl-agent::ollama-provider)))'
	ollama pull $(OLLAMA_TEST_MODEL)
	CL_AGENT_OLLAMA_TEST_MODEL=$(OLLAMA_TEST_MODEL) \
		$(SBCL) --non-interactive --load boot.lisp --eval '(asdf:load-system "cl-agent/tests/ollama")'

# A genuine third-party MCP interoperability suite. npx downloads the pinned
# server automatically on its first run; no LLM provider is required.
test-mcp-external: install-deps
	command -v npx >/dev/null 2>&1 || { echo "npx not found; install Node.js first"; exit 1; }
	$(SBCL) --non-interactive --load boot.lisp --eval '(asdf:test-system "cl-agent/tests/mcp-external")'


# Regenerates data/cl-spec.sdoc (already committed; most people never
# need to run this -- see scripts/build-clspec-data.sh's header comment).
clspec-data:
	./scripts/build-clspec-data.sh

clean:
	rm -rf ocicl/ bin/
