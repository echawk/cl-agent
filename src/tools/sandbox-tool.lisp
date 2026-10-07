;;;; tools/sandbox-tool.lisp -- explicit, policy-enforced shell execution.

(in-package :cl-agent)

(defun sandbox-receipt-string (receipt)
  (with-output-to-string (stream)
    (format stream "Sandboxed command finished.~%")
    (format stream "Exit code: ~a~%" (getf receipt :exit-code))
    (when (getf receipt :timed-out-p)
      (format stream "Timed out.~%"))
    (when (getf receipt :output-truncated-p)
      (format stream "Standard output was truncated.~%"))
    (when (getf receipt :error-output-truncated-p)
      (format stream "Standard error was truncated.~%"))
    (format stream "Elapsed: ~,2fs~%" (getf receipt :real-seconds))
    (when (plusp (length (getf receipt :output)))
      (format stream "Standard output:~%~a~%" (getf receipt :output)))
    (when (plusp (length (getf receipt :error-output)))
      (format stream "Standard error:~%~a" (getf receipt :error-output)))))

(define-tool sandbox-shell (args)
    (:description "Run a shell command under cl-exec-sandbox's workspace-write policy. It may write inside this agent's current workspace only; agent/repository metadata remains protected and network access is isolated. Use this for an immediately bounded command when sandbox enforcement is available. It is distinct from shell, whose managed-job lifecycle is retained for compatibility."
     :effects '(:process :write-workspace)
     :parameters (jobj "type" "object" "properties"
                       (jobj "command" (jobj "type" "string")
                             "reason" (jobj "type" "string")
                             "result_use" (jobj "type" "string")
                             "timeout_seconds" (jobj "type" "integer" "minimum" 1 "maximum" 300))
                       "required" (list "command" "reason" "result_use")))
  (unless (sandbox-available-p)
    (error "The operating system cannot enforce the cl-exec-sandbox policy on this host"))
  (sandbox-receipt-string
   (run-sandboxed-shell-command (required-shell-command args)
                                :timeout (jget args "timeout_seconds" 30))))
