;;;; tools/dap-tool.lisp -- model-facing lifecycle for Daphne adapters.

(in-package :cl-agent)

(defun dap-tool-arguments (arguments)
  (unless (listp arguments)
    (error "DAP adapter arguments must be a JSON array of strings"))
  (unless (every #'stringp arguments)
    (error "Every DAP adapter argument must be a string"))
  arguments)

(define-tool connect-dap-adapter (args)
    (:description "Start and initialize a Debug Adapter Protocol server through Daphne. program is the executable and arguments is its argv after program. This opens a named connection that can later be inspected or closed; it does not itself set breakpoints or execute debug requests."
     :effects '(:process)
     :parameters (jobj "type" "object" "properties"
                       (jobj "name" (jobj "type" "string")
                             "program" (jobj "type" "string")
                             "arguments" (jobj "type" "array" "items" (jobj "type" "string")))
                       "required" (list "name" "program" "arguments")))
  (let ((name (jget args "name"))
        (program (jget args "program")))
    (unless (and (stringp name) (plusp (length name)))
      (error "DAP adapter name must be a non-empty string"))
    (unless (and (stringp program) (plusp (length program)))
      (error "DAP adapter program must be a non-empty string"))
    (connect-dap-adapter name program (dap-tool-arguments (jget args "arguments")))
    (format nil "Connected and initialized DAP adapter ~a." name)))

(define-tool list-dap-adapters (args)
    (:description "List Debug Adapter Protocol connections currently owned by the agent, including their launch command and Daphne session state."
     :parameters (jobj "type" "object" "properties" (jobj)))
  (ignore-errors args)
  (let ((connections (list-dap-connections)))
    (if connections
        (with-output-to-string (stream)
          (dolist (connection connections)
            (format stream "~a: ~{~a~^ ~} (~a)~%"
                    (getf connection :name) (getf connection :command)
                    (getf connection :state))))
        "No DAP adapters are connected.")))

(define-tool disconnect-dap-adapter (args)
    (:description "Close one named Debug Adapter Protocol connection owned by the agent."
     :effects '(:process)
     :parameters (jobj "type" "object" "properties"
                       (jobj "name" (jobj "type" "string"))
                       "required" (list "name")))
  (let ((name (jget args "name")))
    (unless (and (stringp name) (plusp (length name)))
      (error "DAP adapter name must be a non-empty string"))
    (if (disconnect-dap-adapter name)
        (format nil "Disconnected DAP adapter ~a." name)
        (format nil "No DAP adapter named ~a is connected." name))))
