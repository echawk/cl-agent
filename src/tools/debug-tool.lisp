;;;; debug-tool.lisp -- give the agent access to journaled tool failures.

(in-package :cl-agent)

(define-tool list-failures (args)
    (:description "List recent tool failures captured by the debugger (newest first) with their receipt ids, and any active recovery policies. Use inspect-failure with an id to see the condition, the restarts that were available, and the stack."
     :parameters (jobj "type" "object"
                       "properties" (jobj "limit" (jobj "type" "integer" "minimum" 1 "maximum" 100
                                                        "description" "Maximum receipts to list (default 15)."))
                       "required" :empty-array))
  (let* ((limit (jget args "limit" 15))
         (receipts (progn
                     (unless (and (integerp limit) (<= 1 limit 100)) (error "limit must be an integer from 1 to 100"))
                     (list-failure-receipts :limit limit)))
         (policies (loop for tool being the hash-keys of *failure-recovery-policies* using (hash-value policy)
                         collect (format nil "~a: ~(~a~)~@[ up to ~d time~:p~]" tool (getf policy :action)
                                         (getf policy :max-retries)))))
    (format nil "Failures:~%~{~a~^~%~}~%Recovery policies:~%~{~a~^~%~}"
            (or (mapcar #'format-failure-receipt-line receipts) (list "none recorded"))
            (or policies (list "none")))))

(define-tool inspect-failure (args)
    (:description "Show one captured tool failure in full: tool, arguments, condition type and report, the restarts that were available when it happened, the decision taken, and a bounded backtrace. Works for failures from this process and from subagents."
     :parameters (jobj "type" "object"
                       "properties" (jobj "id" (jobj "type" "string" "description" "A receipt id from list-failures or a tool error message."))
                       "required" (list "id")))
  (let ((id (jget args "id")))
    (unless (safe-failure-id-p id) (error "id must be a receipt id like those shown by list-failures"))
    (let ((receipt (load-failure-receipt id)))
      (if receipt
          (format-failure-receipt receipt)
          (format nil "No failure receipt ~a. Use list-failures to see recent ones." id)))))

(define-tool set-failure-recovery (args)
    (:description "Set how the debugger recovers when a given tool raises an error: action \"retry\" re-runs the call automatically up to max_retries times (default 1, hard limit 3) -- only for tools that are safe to repeat, because a retry repeats side effects; action \"abort\" (default behaviour) clears the policy and reports the error to you."
     :effects (list :self-modify)
     :parameters (jobj "type" "object"
                       "properties" (jobj "tool" (jobj "type" "string")
                                          "action" (jobj "type" "string" "enum" (list "retry" "abort"))
                                          "max_retries" (jobj "type" "integer" "minimum" 1 "maximum" 3))
                       "required" (list "tool" "action")))
  (let ((tool (jget args "tool")) (action (jget args "action")) (retries (jget args "max_retries" 1)))
    (unless (and (stringp tool) (find-tool tool)) (error "Unknown tool ~s" tool))
    (unless (member action '("retry" "abort") :test #'equal) (error "action must be \"retry\" or \"abort\""))
    (unless (and (integerp retries) (<= 1 retries *failure-retry-limit*))
      (error "max_retries must be an integer from 1 to ~d" *failure-retry-limit*))
    (if (equal action "abort")
        (progn (remhash tool *failure-recovery-policies*)
               (unpublish-component :recovery-policy tool)
               (format nil "~a errors will be reported to you without retrying." tool))
        (progn (setf (gethash tool *failure-recovery-policies*)
                     (list :action :retry :max-retries retries))
               (publish-component :recovery-policy tool :effects (list :self-modify)
                                  :metadata (list :action :retry :max-retries retries))
               (format nil "~a will be retried automatically up to ~d time~:p when it raises an error." tool retries)))))
