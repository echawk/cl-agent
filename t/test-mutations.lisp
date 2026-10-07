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
      (commit-mutation transaction)
      (check-equal (mutation-state transaction) :committed)
      (check (probe-file (mutation-target transaction)))
      (check (extension-enabled-p "mutation-commit.lisp"))
      (check (probe-file (mutation-journal-path transaction)))
      (unregister-tool "mutation-commit-tool"))))
