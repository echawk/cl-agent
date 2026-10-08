;;;; t/test-tasks.lisp -- concurrent, process-isolated subagent tasks.
;;;;
;;;; The child processes are real SBCLs.  A scripted provider is installed in
;;;; each child through the :BEFORE-SUBAGENT-START hook and :SETUP-FORMS, which
;;;; also exercises those extension points.  A model named "slow-N" sleeps N
;;;; seconds inside the child before answering.

(in-package :cl-agent)

(defparameter *test-child-provider-source*
  "(progn
     (defclass test-scripted-provider (llm-provider) ())
     (defmethod provider-default-model ((p test-scripted-provider)) \"fast\")
     (defmethod chat ((p test-scripted-provider) messages tools)
       (when (search \"slow-\" (provider-model p))
         (sleep (parse-integer (provider-model p) :start 5)))
       (list :role \"assistant\" :tool-calls nil
             :content (format nil \"scripted ~a with ~d tools\" (provider-model p) (length tools))))
     (register-provider-class :scripted 'test-scripted-provider))")

(defun call-with-scripted-children (model thunk)
  "Run THUNK with every subagent contract rewritten to use the scripted child provider."
  (let ((name (format nil "test-scripted-child-~d" (random 1000000))))
    (add-hook :before-subagent-start name
              (lambda (contract)
                (setf (getf contract :provider) (list :keyword :scripted :model model)
                      (getf contract :setup-forms) (list *test-child-provider-source*))
                contract))
    (unwind-protect (funcall thunk)
      (remove-hook :before-subagent-start name))))

(defun test-wait-until (predicate &optional (seconds 90))
  (loop repeat (* seconds 10)
        when (funcall predicate) return t
        do (sleep 0.1)))

(deftest subagent-task-runs-a-real-provider-in-a-child-process ()
  (let ((parent (make-session (make-instance 'ollama-provider))))
    (call-with-scripted-children
     "fast"
     (lambda ()
       (let ((task (start-subagent-task parent "say hello" "Be brief.")))
         (multiple-value-bind (task terminal-p) (wait-subagent-task task :timeout 120)
           (check terminal-p "task finishes")
           (check-equal (subagent-task-state task) :succeeded)
           (check (search "scripted fast with 6 tools" (getf (subagent-task-result task) :report))
                  "child ran the contract's provider with the default tool set")
           (check (search "Subagent report" (format-subagent-report task)))
           (check-equal (length (session-messages parent)) 1 "parent history is untouched")))))))

(deftest subagent-tasks-overlap-and-cancel-independently ()
  (let ((parent (make-session (make-instance 'ollama-provider)))
        (log nil)
        (hook (format nil "test-transition-log-~d" (random 1000000))))
    (add-hook :subagent-task-transition hook
              (lambda (snapshot) (push (list (getf snapshot :id) (getf snapshot :state)) log)))
    (unwind-protect
         (let (slow keeper)
           (call-with-scripted-children
            "slow-4"
            (lambda ()
              (setf keeper (start-subagent-task parent "keep going" "Be brief."))
              (setf slow (start-subagent-task parent "will be cancelled" "Be brief."))))
           (check (test-wait-until
                   (lambda () (and (eq (subagent-task-state keeper) :running)
                                   (eq (subagent-task-state slow) :running))))
                  "both children are running at the same time")
           (cancel-subagent-task slow)
           (check-equal (subagent-task-state slow) :cancelled)
           (wait-subagent-task keeper :timeout 120)
           (check-equal (subagent-task-state keeper) :succeeded
                        "cancelling one leaves the other's result usable")
           (check (search "scripted slow-4" (getf (subagent-task-result keeper) :report)))
           (check (member (list (subagent-task-id slow) :cancelled) log :test #'equal)
                  "transition hook observed the cancellation"))
      (remove-hook :subagent-task-transition hook))))

(deftest subagent-contract-refuses-ungrantable-tools-and-honours-roles ()
  (let ((parent (make-session (make-instance 'ollama-provider))))
    (check (search "may not be granted"
                   (handler-case (build-subagent-contract parent "t" "s" :tools '("write-file"))
                     (error (c) (princ-to-string c)))))
    (register-subagent-role "test-role" :tools '("read-file") :max-seconds 7
                                        :system-prompt "Role prompt.")
    (unwind-protect
         (let ((contract (build-subagent-contract parent "t" nil :role "test-role")))
           (check-equal (getf contract :tools) '("read-file"))
           (check-equal (getf contract :max-seconds) 7)
           (check-equal (getf contract :system) "Role prompt.")
           (check-equal (getf contract :depth) 1)
           (check (gethash (component-id :subagent-role "test-role") *components*)))
      (remhash "test-role" *subagent-roles*)
      (unpublish-component :subagent-role "test-role"))
    (check (search "Unknown subagent role"
                   (handler-case (build-subagent-contract parent "t" "s" :role "nope")
                     (error (c) (princ-to-string c)))))))

(deftest subagent-task-state-machine-rejects-invalid-transitions ()
  (let ((task (make-instance 'subagent-task :id "state-machine-fixture" :contract nil)))
    (check (handler-case (progn (transition-subagent-task task :succeeded) nil)
             (invalid-subagent-transition () t)))
    (transition-subagent-task task :running)
    (transition-subagent-task task :failed :note "boom")
    (check-equal (settle-subagent-task task :cancelled) nil "terminal tasks are never reopened")
    (check-equal (subagent-task-state task) :failed)
    (unpublish-component :subagent-task "state-machine-fixture")))

(deftest subagent-worker-result-redacts-provider-secrets ()
  (let ((result (read-worker-result (list :status :error :message "bad key sk-secret-1" :output "sk-secret-1")
                                    "sk-secret-1")))
    (check-equal (getf result :message) "bad key [redacted]")
    (check-equal (getf result :output) "[redacted]")))
