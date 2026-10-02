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
  :depends-on ("drakma" "shasht" "uiop"
               "cl-mcp" "cl-mcp/client" "bordeaux-threads"  ; src/mcp/*.lisp
               "clingon"                                     ; CLI parsing, src/main.lisp
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
     (:file "hooks")
     (:file "json-util")
     (:file "http")
     (:file "config")
     (:file "tools")
     (:module "mcp"
      :serial t
      :components
      ((:file "client")
       (:file "server")))
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
     (:file "extensions")
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
       (:file "extensions-tool")
       (:file "clspec-tool")
       (:file "mcp-tool")))
     (:file "repl")
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
   (:file "test-config")
   (:file "test-extensions")
   (:file "test-clspec")
   (:file "test-repl")
   (:file "test-mcp")
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
