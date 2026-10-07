;;;; sandbox.lisp -- cl-agent adapter over cl-exec-sandbox.

(in-package :cl-agent)

(defparameter *sandbox-output-limit* 65536)

(defun sandbox-available-p ()
  "Whether this host can enforce cl-exec-sandbox's baseline policy."
  (cl-exec-sandbox:sandbox-supported-p :available-p))

(defun make-agent-sandbox-policy (&key (workspace-roots (list (uiop:getcwd)))
                                       (network :isolated))
  "Create cl-agent's conservative workspace-write policy.

The policy protects repository/agent metadata through cl-exec-sandbox's
defaults.  Callers must still make authority decisions; this is enforcement,
not an approval system."
  (cl-exec-sandbox:workspace-write-sandbox-policy
   :workspace-roots workspace-roots :network network))

(defun sandbox-result->plist (result)
  (list :exit-code (cl-exec-sandbox:sandbox-result-exit-code result)
        :output (cl-exec-sandbox:sandbox-result-output result)
        :error-output (cl-exec-sandbox:sandbox-result-error-output result)
        :timed-out-p (cl-exec-sandbox:sandbox-result-timed-out-p result)
        :real-seconds (cl-exec-sandbox:sandbox-result-real-seconds result)
        :output-truncated-p (cl-exec-sandbox:sandbox-result-output-truncated-p result)
        :error-output-truncated-p (cl-exec-sandbox:sandbox-result-error-output-truncated-p result)))

(defun run-sandboxed-shell-command (command &key policy (timeout 30) working-directory)
  "Run COMMAND through cl-exec-sandbox and return a data-only receipt.

This is a deliberate new adapter; existing managed shell jobs retain their
current lifecycle until P4 routes all execution through policy/approval."
  (unless (and (stringp command) (plusp (length (string-trim " " command))))
    (error "Sandbox command must be a non-empty string"))
  (sandbox-result->plist
   (cl-exec-sandbox:run-sandboxed
    "/bin/sh" (list "-c" command)
    :policy (or policy (make-agent-sandbox-policy))
    :working-directory (or working-directory (uiop:getcwd))
    :timeout timeout :output-limit *sandbox-output-limit*
    :error-output-limit *sandbox-output-limit*)))
