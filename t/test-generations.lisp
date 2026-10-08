;;;; t/test-generations.lisp -- durable generation store wiring.

(in-package :cl-agent)

(deftest generation-store-uses-sexp-store-for-artifacts ()
  (with-temp-config-dir ()
    (let* ((store (agent-generation-store))
           (path (merge-pathnames "fixture.sexp" (generations-directory)))
           (form '(:fixture :version 1 :value "snapshot")))
      (funcall (sbcl-generations:generation-store-write-function store) path form)
      (check-equal (funcall (sbcl-generations:generation-store-read-function store) path) form)
      (write-string-atomically path "(:fixture 1)\n(:extra 2)")
      (check-condition error
        (funcall (sbcl-generations:generation-store-read-function store) path)
        "generation artifacts reject concatenated snapshots"))))

(deftest generation-metadata-records-the-committed-mutation-frontier ()
  (with-temp-config-dir ()
    (ensure-mutation-directories)
    (sexp-store:snapshot-write
     (merge-pathnames "committed.sexp" (mutation-journal-directory))
     '(:id "committed" :state :committed))
    (sexp-store:snapshot-write
     (merge-pathnames "failed.sexp" (mutation-journal-directory))
     '(:id "failed" :state :failed))
    (check-equal (committed-mutation-ids) '("committed"))
    (check-equal (getf (generation-metadata "generation-id" (generation-precheck))
                       :committed-mutations)
                 '("committed"))))

(deftest generation-controls-are-registered-tools ()
  (dolist (name '("list-generations" "checkpoint-generation" "rollback-generation"))
    (check (find-tool name) (format nil "~a is available to the agent" name))))
