;;;; t/test-mutations.lisp -- staged extension transaction behavior.

(in-package :cl-agent)

(deftest mutation-proposal-does-not-change-active-source-or-registry ()
  (with-temp-config-dir ()
    (let ((transaction (propose-extension
                        "mutation-proposal"
                        "(in-package :cl-agent) (define-tool mutation-proposal-tool (args) (:description \"x\") \"ok\")")))
      (check-equal (mutation-state transaction) :proposed)
      (check (probe-file (mutation-staged-source transaction)))
      (check-equal (probe-file (mutation-target transaction)) nil)
      (check-equal (find-tool "mutation-proposal-tool") nil))))

(deftest mutation-install-discard-restores-registry-state ()
  (with-temp-config-dir ()
    (let ((transaction (propose-extension
                        "mutation-discard"
                        "(in-package :cl-agent) (define-tool mutation-discard-tool (args) (:description \"x\") \"ok\")")))
      (preflight-mutation transaction)
      (check (find :clean-probe (mutation-receipts transaction)
                   :key (lambda (receipt) (getf receipt :status))))
      (install-mutation transaction)
      (check (find-tool "mutation-discard-tool"))
      (exercise-mutation transaction)
      (check-equal (mutation-state transaction) :exercised)
      (discard-mutation transaction)
      (check-equal (find-tool "mutation-discard-tool") nil))))

(deftest failed-mutation-install-keeps-active-file-and-registry-unchanged ()
  (with-temp-config-dir ()
    (let* ((target (write-extension-file "mutation-failure" "(in-package :cl-agent)"))
           (before (uiop:read-file-string target))
           (transaction (propose-extension
                         "mutation-failure"
                         "(in-package :cl-agent) (define-tool mutation-failure-tool (args) (:description \"x\") \"ok\") (error \"fail after registration\")")))
      ;; The fresh process catches the staged load error before the parent
      ;; image ever receives the partially registering source.
      (check-condition error (preflight-mutation transaction))
      (check-equal (uiop:read-file-string target) before)
      (check-equal (find-tool "mutation-failure-tool") nil)
      (check-equal (mutation-state transaction) :failed))))

(deftest committed-mutation-publishes-source-enablement-and-journal ()
  (with-temp-config-dir ()
    (let ((transaction (propose-extension
                        "mutation-commit"
                        "(in-package :cl-agent) (define-tool mutation-commit-tool (args) (:description \"x\") \"ok\")")))
      (preflight-mutation transaction)
      (install-mutation transaction)
      (exercise-mutation transaction)
      (commit-mutation transaction)
      (check-equal (mutation-state transaction) :committed)
      (check (probe-file (mutation-target transaction)))
      (check (extension-enabled-p "mutation-commit.lisp"))
      (check (probe-file (mutation-journal-path transaction)))
      (unregister-tool "mutation-commit-tool"))))

(deftest mutation-exercises-run-before-commit-and-record-evidence ()
  (with-temp-config-dir ()
    (let ((transaction
            (propose-extension
             "mutation-exercise-pass"
             "(in-package :cl-agent)
               (define-tool mutation-exercise-pass-tool (args) (:description \"x\") \"ready\")
               (define-mutation-exercise mutation-exercise-pass ()
                 (unless (search \"ready\" (call-tool \"mutation-exercise-pass-tool\" (jobj)))
                   (error \"tool smoke test failed\")))")))
      (preflight-mutation transaction)
      (install-mutation transaction)
      (exercise-mutation transaction)
      (check-equal (mutation-state transaction) :exercised)
      (check (find 'mutation-exercise-pass (mutation-receipts transaction)
                   :key (lambda (receipt) (getf receipt :exercise-id))))
      (commit-mutation transaction)
      (unregister-tool "mutation-exercise-pass-tool"))))

(deftest failed-mutation-exercise-rolls-back-and-blocks-commit ()
  (with-temp-config-dir ()
    (let ((transaction
            (propose-extension
             "mutation-exercise-fail"
             "(in-package :cl-agent)
               (define-tool mutation-exercise-fail-tool (args) (:description \"x\") \"ready\")
               (define-mutation-exercise mutation-exercise-fail ()
                 (error \"deliberate exercise failure\"))")))
      (preflight-mutation transaction)
      (install-mutation transaction)
      (check-condition error (exercise-mutation transaction))
      (check-equal (mutation-state transaction) :failed)
      (check-equal (find-tool "mutation-exercise-fail-tool") nil)
      (check-condition error (commit-mutation transaction)))))
