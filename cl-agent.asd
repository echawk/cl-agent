;;;; cl-agent.asd -- system definition for cl-agent
;;;;
;;;; cl-agent is a small command-line coding agent, in the spirit of
;;;; class-ref/agent-repl.rhm, but written in Common Lisp and designed
;;;; from the start to be extended -- including by itself, at runtime,
;;;; from inside its own running SBCL image.  See src/extensions.lisp
;;;; and README.md ("Self-modification") for the headline feature.
;;;;
;;;; Dependencies are fetched with ocicl (see https://github.com/ocicl/ocicl).
;;;; From a fresh checkout:
;;;;   make install-deps     ; ocicl install, using the committed ocicl.csv lockfile
;;;;   make build             ; produces bin/cl-agent, a standalone executable
;;;;   make run               ; runs the agent from source, no build step
;;;;   make test              ; runs the offline unit test suite
;;;;   make test-ollama       ; pulls a tiny ollama model and runs a live integration test

(asdf:defsystem "cl-agent"
  :description "A self-extending, provider-agnostic command-line coding agent."
  :author "Ethan"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("drakma" "shasht" "uiop" "mallet" "defstar"
               "cl-mcp" "cl-mcp/client" "bordeaux-threads"  ; src/mcp/*.lisp
               "cl-exec-sandbox" "daphne"                      ; sandboxed processes; DAP client
               "surgeon"                                        ; reversible SBCL definition changes
               "cl-jobpond" "clinker-transcript"               ; supervised jobs; transcript projections
               "sbcl-generations" "sbcl-workers"               ; recovery images; isolated workers
               "clasted" "sexp-store" "sexp-config"           ; structural edits; durable data/config
               "lambda-debugger" "agentcomms"                  ; restart debugging; ACP
               "setinka" "idsmall"                             ; typed settings; timestamped IDs
               "cl-lsp" "cl-skills"                           ; agent LSP + Skills
               "clingon" "3bmd" "3bmd-ext-tables"           ; CLI parsing; Markdown web rendering
               "tuition"                                     ; TUI frontend, src/ui/tui.lisp
               "hunchentoot")                                ; web frontend, src/ui/web.lisp
  :build-operation "program-op"
  :build-pathname "bin/cl-agent"
  :entry-point "cl-agent:main"
  ;; :BUILD-PATHNAME is resolved against the system's own :PATHNAME, so
  ;; the source tree is nested one level down (in a "src" :MODULE)
  ;; rather than the system itself being rooted at src/ -- that way
  ;; "bin/cl-agent" lands at the project root (next to this .asd file),
  ;; matching the Makefile, instead of inside src/.
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "conditions")
     (:file "events")
     (:file "components")
     (:file "hooks")
     (:file "json-util")
     (:file "http")
     (:file "storage")
     (:file "config")
     (:file "settings")
     (:file "debug")
     (:file "tools")
     (:file "lsp")
     (:file "skills")
     (:module "mcp"
      :serial t
      :components
      ((:file "client")
       (:file "server")))
     (:file "sandbox")
     (:file "dap")
     (:file "workers")
     (:file "transcript")
     (:module "providers"
      :serial t
      :components
      ((:file "provider")
       (:file "openai-compatible")
       (:file "registry")
       (:file "reallms")
       (:file "openai")
       (:file "xai")
       (:file "ollama")
       (:file "anthropic")
       (:file "apfel")))
     (:file "clspec")
     (:file "apropos")
     (:file "quality")
     (:file "structural")
     (:file "extensions")
     (:module "mutation"
      :serial t
      :components
      ((:file "protocol")
       (:file "probe")
       (:file "definitions")
       (:file "exercises")
       (:file "transaction")
       (:file "journal")))
     (:file "generations")
     (:file "doctor")
     (:module "ui"
      :serial t
      :components
      ((:file "frontend")
       (:file "cli")
       (:file "tui")
       (:file "web")))
     (:module "tools-builtin"
     :pathname "tools"
     :serial t
     :components
     ((:file "shell")
       (:file "sandbox-tool")
       (:file "file-tool")
       (:file "structural-tool")
       (:file "lsp-tool")
       (:file "skills-tool")
       (:file "quality-tool")
       (:file "asdf-tool")
       (:file "extensions-tool")
       (:file "llm-tool")
       (:file "clspec-tool")
       (:file "apropos-tool")
       (:file "mcp-tool")
       (:file "components-tool")
       (:file "dap-tool")
       (:file "debug-tool")
       (:file "generations-tool")))
     (:file "tasks")
     (:file "repl")
     (:file "acp")
     (:file "main")))))

;; `(asdf:test-op :cl-agent)` / `make test` runs the offline suite, which
;; never touches the network and needs no LLM provider configured.
(asdf:defsystem "cl-agent/tests"
  :description "Offline unit tests for cl-agent."
  :depends-on ("cl-agent")
  :pathname "t"
  :serial t
  :components
  ((:file "framework")
   (:file "test-json")
   (:file "test-hooks")
   (:file "test-tools")
   (:file "test-providers")
   (:file "test-streaming")
   (:file "test-ollama-ensure-ready")
   (:file "test-apfel-ensure-ready")
   (:file "test-storage")
   (:file "test-config")
   (:file "test-settings")
   (:file "test-skills")
   (:file "test-lsp")
   (:file "test-extensions")
   (:file "test-mutations")
   (:file "test-generations")
   (:file "test-doctor")
   (:file "test-quality")
   (:file "test-structural")
   (:file "test-clspec")
   (:file "test-apropos")
   (:file "test-components")
   (:file "test-repl")
   (:file "test-tasks")
   (:file "test-input")
   (:file "test-debugger")
   (:file "test-acp")
   (:file "test-mcp")
   (:file "test-integrations")
   (:file "test-ui"))
  :perform (asdf:test-op (op system)
             (uiop:symbol-call :cl-agent :run-all-tests)))

;; `make test-ollama` loads this separately (see Makefile) because it
;; requires a reachable ollama server and is not part of the default suite.
(asdf:defsystem "cl-agent/tests/ollama"
  :description "Live integration test against a local ollama server."
  :depends-on ("cl-agent")
  :pathname "t"
  :serial t
  :components
  ((:file "framework")
   (:file "test-ollama-integration")))

;; Separate from the offline suite: starts the published npm filesystem MCP
;; server through npx and therefore needs network access on a cold cache.
(asdf:defsystem "cl-agent/tests/mcp-external"
  :description "Live interoperability tests against published MCP servers."
  :depends-on ("cl-agent")
  :pathname "t"
  :serial t
  :components ((:file "framework")
               (:file "test-mcp-external"))
  :perform (asdf:test-op (op system)
             (uiop:symbol-call :cl-agent :run-all-tests)))
