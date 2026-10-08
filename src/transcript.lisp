;;;; transcript.lisp -- portable, reconciled provider-history projection.

(in-package :cl-agent)

(defun transcript-object (&rest entries)
  (apply #'clinker-transcript:json-object entries))

(defun session-message->transcript-items (message)
  "Convert one normalized session MESSAGE to portable transcript items.
The provider-neutral message remains the authoritative application record; the
items are the validated projection used at the provider boundary."
  (let ((role (getf message :role)))
    (cond
      ((string= role "user") (list (clinker-transcript:user-message-item (or (getf message :content) ""))))
      ((string= role "tool")
       (list (clinker-transcript:function-call-output-item
              (getf message :tool-call-id) (or (getf message :content) ""))))
      ((and (string= role "assistant") (getf message :tool-calls))
       (mapcar (lambda (call)
                 (transcript-object "type" "function_call" "call_id" (getf call :id)
                                    "name" (getf call :name)
                                    "arguments" (json-encode (getf call :arguments))))
               (getf message :tool-calls)))
      (t (list (transcript-object "type" "message" "role" role
                                "content" (vector (transcript-object "type" "text"
                                                                     "text" (or (getf message :content) "")))))))))

(defun session-provider-messages (session)
  "Return SESSION history after Clinker validation, preserving normalized form.
Each portable item carries identity metadata back to its originating normalized
message. Reconciliation catches duplicate/missing tool results before a
provider sees an invalid transcript."
  (let* ((projection (clinker-transcript:make-projection))
         (metadata (clinker-transcript:projection-metadata-table projection :session-message)))
    (dolist (message (session-messages session))
      (dolist (item (session-message->transcript-items message))
        (setf (gethash item metadata) message)
        (clinker-transcript:projection-append projection item)))
    (let* ((items (clinker-transcript:projection-items projection))
           (reconciled (clinker-transcript:reconciliation-items
                        (clinker-transcript:reconcile-items items)))
           (messages nil))
      (dolist (item reconciled (nreverse messages))
        (let ((message (gethash item metadata)))
          ;; One assistant message may expand into several call items.
          (when (and message (not (member message messages :test #'eq)))
            (push message messages)))))))
