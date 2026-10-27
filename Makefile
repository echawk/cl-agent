# Makefile
#
# `ocicl install` (no arguments) reads the committed ocicl.csv lockfile
# and re-populates ./ocicl/ from it -- see boot.lisp and README.md for
# why this project's dependency story is just "run ocicl install".

SBCL ?= sbcl
# No ~/.sbclrc: a dependency missing from ocicl.csv must fail here, not be
# found quietly in whatever the init file sets up (scripts/check-deps.lisp).
SBCL_FLAGS ?= --no-userinit
OLLAMA_TEST_MODEL ?= qwen2.5:0.5b
# The binary's heap (it keeps the building SBCL's): room for big buffers and
# for the agent's memory guard to stop runaway code well before it runs out.
HEAP_MB ?= 4096

.PHONY: all check-env install-deps build run test test-ollama test-mcp-external clspec-data clean

# Tests keep every file they write (sessions, tasks, extensions, config) in
# a fresh temporary directory, never ~/.config/cl-agent/: CL_AGENT_CONFIG_DIR
# points cl-agent there, and the directory is removed afterwards, pass or fail.
with-test-dir = dir=$$(mktemp -d "$${TMPDIR:-/tmp}/cl-agent-test.XXXXXX") || exit 1; \
	CL_AGENT_CONFIG_DIR="$$dir" $(1); status=$$?; rm -rf "$$dir"; exit $$status

all: build

check-env:
	./check-env.sh

# third-party/slt is a git submodule (slt, the Terminal tab's terminal
# emulator, pinned to one commit): fetched here when it is missing.
install-deps: check-env
	@test -f third-party/slt/slt.asd || git submodule update --init third-party/slt
	ocicl install

build: install-deps
	$(SBCL) --dynamic-space-size $(HEAP_MB) $(SBCL_FLAGS) --non-interactive --load boot.lisp --eval '(asdf:make :cl-agent)'

run: install-deps
	$(SBCL) --script run.lisp -- $(ARGS)

test: install-deps
	$(call with-test-dir,$(SBCL) $(SBCL_FLAGS) --non-interactive --load boot.lisp --eval '(asdf:test-system "cl-agent/tests")')

# Starts `ollama serve` if it isn't already running (same
# PROVIDER-ENSURE-READY logic cl-agent itself uses, see
# providers/ollama.lisp), then pulls a small model so the test has
# something to talk to.
test-ollama: install-deps
	command -v ollama >/dev/null 2>&1 || { echo "ollama not found; install it from https://ollama.com"; exit 1; }
	$(SBCL) $(SBCL_FLAGS) --non-interactive --load boot.lisp --eval '(asdf:load-system "cl-agent")' \
		--eval '(cl-agent::provider-ensure-ready (make-instance (quote cl-agent::ollama-provider)))'
	ollama pull $(OLLAMA_TEST_MODEL)
	$(call with-test-dir,CL_AGENT_OLLAMA_TEST_MODEL=$(OLLAMA_TEST_MODEL) $(SBCL) $(SBCL_FLAGS) --non-interactive --load boot.lisp --eval '(asdf:load-system "cl-agent/tests/ollama")')

# A genuine third-party MCP interoperability suite. npx downloads the pinned
# server automatically on its first run; no LLM provider is required.
test-mcp-external: install-deps
	command -v npx >/dev/null 2>&1 || { echo "npx not found; install Node.js first"; exit 1; }
	$(call with-test-dir,$(SBCL) $(SBCL_FLAGS) --non-interactive --load boot.lisp --eval '(asdf:test-system "cl-agent/tests/mcp-external")')


# Regenerates data/cl-spec.sdoc (already committed; most people never
# need to run this -- see scripts/build-clspec-data.sh's header comment).
clspec-data:
	./scripts/build-clspec-data.sh

clean:
	rm -rf ocicl/ bin/
