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
    (format t "~&$ ~a~%" command)
    (force-output)
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program command :force-shell t
                                   :output :string
                                   :error-output :string
                                   :ignore-error-status t)
      (let ((combined (concatenate 'string output error-output)))
        (format t "~a" combined)
        (force-output)
        (format nil "Exit code: ~d~%~a" exit-code combined)))))
