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

(deftest structural-query-is-read-only-and-exposes-snapshot-anchored-matches ()
  (if (structural-program-on-path "ast-grep")
      (let ((path (merge-pathnames (format nil "cl-agent-structural-query-~d.js" (random 1000000))
                                   (uiop:temporary-directory))))
        (unwind-protect
             (progn
               (write-string-atomically path (format nil "foo(1);~%foo(2);"))
               (multiple-value-bind (snapshot matches)
                   (query-structural-file (namestring path) "javascript" "foo($A)")
                 (check-equal (length matches) 2)
                 (check-equal (mapcar #'clasted:match-text matches) '("foo(1)" "foo(2)"))
                 (check (search "matches: 2" (format-structural-query snapshot matches)))
                 (check-equal (uiop:read-file-string path) (format nil "foo(1);~%foo(2);"))))
          (ignore-errors (delete-file path))))
      (check t "ast-grep is optional; query tests remain runnable without it")))

(deftest structural-publication-validates-the-entire-batch-before-writing ()
  (let ((left (merge-pathnames (format nil "cl-agent-structural-left-~d.txt" (random 1000000))
                               (uiop:temporary-directory)))
        (right (merge-pathnames (format nil "cl-agent-structural-right-~d.txt" (random 1000000))
                                (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (write-string-atomically left "left")
           (write-string-atomically right "right")
           (let* ((left-snapshot (make-file-structural-snapshot (namestring left)))
                  (right-snapshot (make-file-structural-snapshot (namestring right)))
                  (left-plan (clasted:make-edit-plan :snapshot left-snapshot
                                                     :edits (list (clasted:make-edit :start 0 :end 4 :replacement "LEFT"))))
                  (right-plan (clasted:make-edit-plan :snapshot right-snapshot
                                                      :edits (list (clasted:make-edit :start 0 :end 5 :replacement "RIGHT")))))
             (write-string-atomically right "changed")
             (check-condition error (publish-structural-plans (list left-plan right-plan)))
             (check-equal (uiop:read-file-string left) "left"
                          "the current plan must not publish when another plan is stale")
             (let ((fresh-right (clasted:make-edit-plan
                                 :snapshot (make-file-structural-snapshot (namestring right))
                                 :edits (list (clasted:make-edit :start 0 :end 7 :replacement "RIGHT")))))
               (publish-structural-plans (list left-plan fresh-right))
               (check-equal (uiop:read-file-string left) "LEFT")
               (check-equal (uiop:read-file-string right) "RIGHT"))))
      (ignore-errors (delete-file left))
      (ignore-errors (delete-file right)))))

(deftest structural-rewrite-planner-is-registered ()
  (check (find-tool "structural-rewrite-plan"))
  (check (find-tool "structural-query")))
