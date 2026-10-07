;;;; main.lisp -- CLI entry point. This is cl-agent.asd's :entry-point,
;;;; so it's what `bin/cl-agent` (after `make build`) and
;;;; `sbcl --script run.lisp` both end up calling.
;;;;
;;;; CLI parsing is clingon (https://github.com/dnaeon/clingon), not a
;;;; hand-rolled argv loop: flag/value parsing, `--opt=value` and
;;;; `--opt value` both working, `--help`/`--version` generation, and
;;;; clear errors on an unknown or malformed option are all things a
;;;; real parsing library is worth depending on for, the same
;;;; reasoning as using drakma/shasht instead of hand-rolled HTTP/JSON.

(in-package :cl-agent)

(defun resolve-provider-keyword (cli-provider config)
  (or cli-provider
      (let ((env-provider (env "CL_AGENT_PROVIDER")))
        (and env-provider (intern (string-upcase env-provider) :keyword)))
      (config-value config :provider)
      :reallms))

(defun resolve-ui-keyword (cli-ui config)
  "Same resolution order as RESOLVE-PROVIDER-KEYWORD: --ui flag >
CL_AGENT_UI env var > :ui in config.lisp > :cli."
  (or (and cli-ui (intern (string-upcase cli-ui) :keyword))
      (let ((env-ui (env "CL_AGENT_UI")))
        (and env-ui (intern (string-upcase env-ui) :keyword)))
      (config-value config :ui)
      :cli))

(defun prompt-for-provider-model (provider)
  "Offer PROVIDER's live /models result and return the selected model.
Empty input, EOF, or an unavailable endpoint retains the provider default."
  (let ((default (provider-model provider)))
    (handler-case
        (let ((models (provider-list-models provider)))
          (if (null models)
              default
              (progn
                (format *query-io* "~&No model is configured. Available models from ~a:~%"
                        (provider-display-name provider))
                (loop for model in models for index from 1
                      do (format *query-io* "  ~d) ~a~%" index model))
                (format *query-io* "Choose a number or exact model ID [~a]: " default)
                (finish-output *query-io*)
                (let ((choice (read-line *query-io* nil "")))
                  (cond ((zerop (length (string-trim " " choice))) default)
                        ((ignore-errors
                           (let ((index (parse-integer choice :junk-allowed nil)))
                             (and (<= 1 index (length models)) (nth (1- index) models)))))
                        ((member choice models :test #'string=) choice)
                        (t
                         (format *query-io* "Unknown model choice ~s; using ~a.~%" choice default)
                         default))))))
      (provider-error (c)
        (format *error-output* "~&[models] Could not list models: ~a~%Using default model ~a.~%" c default)
        default))))

(defun cli-command ()
  "The clingon command: declares cl-agent's command-line surface.
Built fresh per call (not a DEFPARAMETER) since its :DESCRIPTION
mentions the currently-registered provider list, which an extension
could change between calls."
  (clingon:make-command
   :name "cl-agent"
   :description "A self-extending, provider-agnostic command-line coding agent."
   :usage "[options] [\"initial task\"]"
   :long-description
   (format nil "With no \"initial task\", starts the interactive REPL (/help for ~
                 commands, Ctrl-D to exit). With one, runs that task first.~%~%~
                 Known providers: ~{~a~^, ~}" (mapcar #'car (list-providers)))
   :options
   (list
    (clingon:make-option :string :long-name "provider" :short-name #\p :key :provider
                          :description "LLM provider to use (see the provider list below). Defaults to the CL_AGENT_PROVIDER env var, then :provider in config.lisp, then reallms.")
    (clingon:make-option :string :long-name "model" :short-name #\m :key :model
                          :description "Model name, overriding the provider's own default.")
    (clingon:make-option :string :long-name "config-dir" :key :config-dir
                          :description "Use PATH instead of ~/.config/cl-agent/ for config.lisp and extensions/.")
    (clingon:make-option :string :long-name "ui" :key :ui
                          :description "Frontend to run: cli (default), tui, web, or one an extension registered. See src/ui/frontend.lisp.")
    (clingon:make-option :flag :long-name "mcp-serve" :key :mcp-serve
                          :description "Run as an MCP server over stdio instead of the chat REPL, exposing every registered tool to an external MCP client (see src/mcp/server.lisp).")
    (clingon:make-option :flag :long-name "doctor" :key :doctor
                          :description "Report local configuration and capability health without contacting providers or starting external services."))
   :handler #'cli-handler))

(defun cli-handler (cmd)
  "Resolution order for every setting is: CLI flag > environment
variable (where one exists) > config.lisp > a documented default --
see RESOLVE-PROVIDER-KEYWORD and the inline uses below. Never signals
out to the top level on an ordinary configuration mistake (missing API
key, unknown provider name): those are reported with a readable
message and a non-zero exit, not a Lisp backtrace."
  (when (clingon:getopt cmd :config-dir)
    (setf *config-directory* (uiop:ensure-directory-pathname (clingon:getopt cmd :config-dir))))
  (if (clingon:getopt cmd :doctor)
      (let ((results (run-doctor)))
        (format t "~a~%" (format-doctor-report results))
        (unless (doctor-healthy-p results) (uiop:quit 1)))
      (progn
        (ensure-config-directory)
        (let ((config (load-user-config))
              (task (format nil "~{~a~^ ~}" (clingon:command-arguments cmd))))
          (handler-case
        (let* ((provider-keyword (resolve-provider-keyword (let ((p (clingon:getopt cmd :provider)))
                                                              (and p (intern (string-upcase p) :keyword)))
                                                            config))
               (configured-model (or (clingon:getopt cmd :model) (config-value config :model)))
               (provider (make-provider provider-keyword
                                         :model configured-model
                                         :base-url (config-value config :base-url)
                                         :api-key-env (config-value config :api-key-env)
                                         :ensure-ready t)))
          (unless configured-model
            (setf (provider-model provider) (prompt-for-provider-model provider)))
          (multiple-value-bind (loaded failed) (load-enabled-extensions)
            (declare (ignore loaded))
            (when failed
              (format *error-output* "~&~d extension(s) failed to load; see above.~%" (length failed))))
          ;; Catalog discovery is cheap and metadata-only. LSP executables are
          ;; inspected now but their processes remain lazy until a tool call.
          (handler-case (initialize-skills)
            (error (c) (format *error-output* "~&[skills] ~a~%" c)))
          (handler-case
              (multiple-value-bind (available unavailable) (initialize-lsp)
                (declare (ignore available))
                (when unavailable
                  (format *error-output* "~&[lsp] unavailable commands: ~{~a~^, ~}~%" unavailable)))
            (error (c) (format *error-output* "~&[lsp] ~a~%" c)))
          (connect-configured-mcp-servers config)
          (if (clingon:getopt cmd :mcp-serve)
              (run-cl-agent-mcp-server :name (provider-display-name provider))
              (progn
                (format t "~&cl-agent -- ~a (~a)~%Type /help for commands, Ctrl-D to exit.~%"
                        (provider-display-name provider) (provider-model provider))
                (run-repl (make-session provider
                                        :frontend (make-frontend (resolve-ui-keyword (clingon:getopt cmd :ui) config))
                                        :system-prompt (config-value config :system-prompt)
                                        :orchestration-mode (config-value config :orchestration-mode)
                                        :orchestration-tool-limit (config-value config :orchestration-tool-limit)
                                        :max-tool-iterations (config-value config :max-tool-iterations)
                                        :max-subagent-depth (config-value config :max-subagent-depth 1)
                                        :subagent-model-profiles (config-value config :subagent-model-profiles))
                          :initial-task task))))
      (provider-not-found (c)
        (format *error-output* "~&~a~%" c) (uiop:quit 1))
      (missing-api-key (c)
        (format *error-output* "~&~a~%" c) (uiop:quit 1))
      (mcp-error (c)
        (format *error-output* "~&~a~%" c) (uiop:quit 1)))))))

(defun connect-configured-mcp-servers (config)
  "Auto-connect every server listed in config.lisp's :MCP-SERVERS (a
list of (:name STRING :command (STRING...)) plists; see src/config.lisp).
Best-effort: a server that fails to connect is reported to
*ERROR-OUTPUT* and skipped, same policy as a broken extension -- one
unreachable MCP server shouldn't prevent the agent from starting."
  (dolist (spec (mcp-server-specs (config-value config :mcp-servers)))
    (handler-case (connect-mcp-server (getf spec :name) (getf spec :command))
      (mcp-error (c) (format *error-output* "~&[mcp] ~a~%" c)))))

(defun main ()
  (clingon:run (cli-command) (uiop:command-line-arguments)))
