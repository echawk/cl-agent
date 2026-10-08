;;;; t/test-structural.lisp -- Clasted snapshots and publication guards.

(in-package :cl-agent)

(deftest structural-plans-are-preview-only-and-detect-stale-files ()
  (let ((path (merge-pathnames (format nil "cl-agent-structural-~d.lisp" (random 1000000))
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (write-string-atomically path "(defun old () :old)")
           (let* ((snapshot (make-file-structural-snapshot (namestring path)))
                  (plan (clasted:make-edit-plan
                         :snapshot snapshot
                         :edits (list (clasted:make-edit :start 7 :end 10 :replacement "new")))))
             (check-equal (clasted:plan-preview plan) "(defun new () :old)")
             (check (structural-plan-current-p plan))
             (write-string-atomically path "(defun changed () :changed)")
             (check (not (structural-plan-current-p plan))
                    "a plan cannot be published after its source revision changes")))
      (ignore-errors (delete-file path)))))

(deftest structural-plans-reject-overlapping-edits ()
  (let ((snapshot (clasted:make-snapshot :file "fixture" :revision "r1" :text "abcdef")))
    (check-condition clasted:structural-error
      (clasted:make-edit-plan
       :snapshot snapshot
       :edits (list (clasted:make-edit :start 1 :end 4 :replacement "X")
                    (clasted:make-edit :start 3 :end 5 :replacement "Y"))))))

(deftest structural-rewrite-uses-ast-grep-without-writing-source ()
  (if (structural-program-on-path "ast-grep")
      (let ((path (merge-pathnames (format nil "cl-agent-structural-~d.js" (random 1000000))
                                   (uiop:temporary-directory))))
        (unwind-protect
             (progn
               (write-string-atomically path "foo(1);")
               (let ((plan (plan-structural-rewrite (namestring path) "javascript"
                                                    "foo($A)" "bar($A)")))
                 (check-equal (clasted:plan-preview plan) "bar(1);")
                 (check-equal (uiop:read-file-string path) "foo(1);"
                              "a structural plan never publishes its preview")))
          (ignore-errors (delete-file path))))
      (check t "ast-grep is optional; base Clasted tests remain runnable without it")))

(deftest structural-rewrite-planner-is-registered ()
  (check (find-tool "structural-rewrite-plan")))
