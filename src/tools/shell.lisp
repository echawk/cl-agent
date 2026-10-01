;;;; tools/shell.lisp -- the one tool the task this project started
;;;; from requires: run a shell command and show the model what
;;;; happened. Modeled directly on class-ref/agent-repl.rhm's `shell`
;;;; tool (same contract: one fresh shell per call, your permissions,
;;;; no sandbox, no confirmation prompt -- same tradeoff the reference
;;;; Python/Racket/Rhombus agents make, see class-ref/*).

(in-package :cl-agent)

(define-tool shell (args)
    (:description "Run a shell command in the current directory. Each call starts a fresh shell; state (cwd, env vars) does not persist between calls, so chain related steps with && in one command."
     :parameters (jobj "type" "object"
                        "properties" (jobj "command" (jobj "type" "string"
                                                            "description" "The shell command to run."))
                        "required" (list "command")))
  (let ((command (jget args "command")))
    (unless command (error "shell tool called with no \"command\" argument"))
    (unless (stringp command)
      ;; A small/weak model will occasionally send a nested object or
      ;; a number instead of a plain string here; without this check
      ;; UIOP:RUN-PROGRAM's own ETYPECASE failure reaches the model as
      ;; an opaque implementation-detail message ("fell through
      ;; ETYPECASE... wanted one of (STRING LIST)") it has no way to
      ;; act on -- this gives it something it can actually fix and retry.
      (error "shell tool's \"command\" argument must be a plain string, e.g. \"ls -la\" -- got ~a: ~s"
             (string-downcase (type-of command)) command))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program command :force-shell t
                                   :output :string
                                   :error-output :string
                                   :ignore-error-status t)
      (let ((combined (concatenate 'string output error-output)))
        (format nil "Exit code: ~d~%~a" exit-code combined)))))
