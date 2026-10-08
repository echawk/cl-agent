;;;; t/test-debugger.lisp -- lambda-debugger around tool calls.

(in-package :cl-agent)

(defmacro with-debugger-fixture ((&rest hook-forms) &body body)
  "Run BODY with an isolated receipt directory and temporary :TOOL-FAILURE hooks.
Each of HOOK-FORMS is a function form installed under a fresh hook name."
  `(let* ((*config-directory* (merge-pathnames (format nil "debugger-test-~d/" (random 1000000))
                                               (uiop:temporary-directory)))
          (*failure-receipts* nil)
          (names (loop for fn in (list ,@hook-forms)
                       for name = (intern (format nil "TEST-FAILURE-HOOK-~d" (random 1000000)) :keyword)
                       do (add-hook :tool-failure name fn)
                       collect name)))
     (unwind-protect (progn ,@body)
       (dolist (name names) (remove-hook :tool-failure name))
       (ignore-errors (uiop:delete-directory-tree *config-directory* :validate t)))))

(defun failure-id-in (text)
  (let* ((start (search "[failure " text)))
    (and start (subseq text (+ start 9) (position #\Space text :start (+ start 9))))))

(deftest tool-errors-are-journaled-and-inspectable-by-the-agent ()
  (with-debugger-fixture ()
    (define-tool test-debug-boom (args) (:description "always errors")
      (error "kaboom ~a" (jget args "n")))
    (unwind-protect
         (let* ((result (call-tool "test-debug-boom" (jobj "n" 7)))
                (id (failure-id-in result)))
           (check (search "Error running test-debug-boom: kaboom 7" result)
                  "the established error text is preserved")
           (check id "the model is told the receipt id")
           (check (probe-file (failure-receipt-pathname id)) "receipt is a durable file")
           (let ((view (call-tool "inspect-failure" (jobj "id" id))))
             (check (search "tool: test-debug-boom" view))
             (check (search "kaboom 7" view))
             (check (search "restarts that were available" view))
             (check (search "backtrace" view)))
           (setf *failure-receipts* nil)
           (check (search "tool: test-debug-boom" (call-tool "inspect-failure" (jobj "id" id)))
                  "another process can read the receipt from disk")
           (check (search id (call-tool "list-failures" (jobj)))))
      (unregister-tool "test-debug-boom"))))

(deftest failure-receipts-use-complete-sexp-store-snapshots ()
  (with-debugger-fixture ()
    (let* ((receipt (list :id "snapshot-receipt" :tool "fixture" :time 1
                          :condition-type "error" :condition-report "fixture"))
           (path (failure-receipt-pathname (getf receipt :id))))
      (persist-failure-receipt receipt)
      (multiple-value-bind (stored complete-p) (sexp-store:snapshot-read path)
        (check complete-p "the receipt is exactly one store snapshot")
        (check-equal stored receipt))
      ;; A damaged/concatenated file must not be mistaken for a usable receipt.
      (write-string-atomically path "(:id \"snapshot-receipt\")\n(:id \"extra\")")
      (setf *failure-receipts* nil)
      (check-equal (load-failure-receipt "snapshot-receipt") nil
                   "only complete single-form snapshots are loaded"))))

(deftest failure-decisions-can-retry-restart-and-return-values ()
  (let ((calls 0))
    (define-tool test-debug-flaky (args) (:description "fails twice")
      (if (< (incf calls) 3) (error "transient") "recovered"))
    (define-tool test-debug-restarts (args) (:description "offers use-value")
      (restart-case (error "bad input") (use-value (v) (format nil "used ~a" v))))
    (define-tool test-debug-always (args) (:description "always fails")
      (incf calls) (error "permanent"))
    (unwind-protect
         (progn
           (with-debugger-fixture
               ((lambda (ctx) (setf (getf ctx :decision) :retry) ctx))
             (setf calls 0)
             (check-equal (call-tool "test-debug-flaky" (jobj)) "recovered" "retry heals a transient failure")
             (setf calls 0)
             (check (search "Error running test-debug-always" (call-tool "test-debug-always" (jobj))))
             (check-equal calls (1+ *failure-retry-limit*) "retries are capped"))
           (with-debugger-fixture
               ((lambda (ctx)
                  (let ((index (position-if (lambda (r) (search "USE-VALUE" (getf r :report)))
                                            (getf (getf ctx :snapshot) :restarts))))
                    (setf (getf ctx :decision) (list :restart (1+ index) "\"fixed\"")))
                  ctx))
             (check-equal (call-tool "test-debug-restarts" (jobj)) "used fixed"))
           (with-debugger-fixture
               ((lambda (ctx) (setf (getf ctx :decision) (list :return-values "\"stand-in\"")) ctx))
             (check-equal (call-tool "test-debug-always" (jobj)) "stand-in")))
      (dolist (name '("test-debug-flaky" "test-debug-restarts" "test-debug-always"))
        (unregister-tool name)))))

(deftest a-failing-decision-hook-never-escapes-the-agent-loop ()
  (with-debugger-fixture ((lambda (ctx) (declare (ignore ctx)) (error "hook bug")))
    (define-tool test-debug-hooked (args) (:description "errors") (error "original"))
    (unwind-protect
         (let* ((result (call-tool "test-debug-hooked" (jobj)))
                (receipt (load-failure-receipt (failure-id-in result))))
           (check (search "Error running test-debug-hooked: original" result))
           (check (search "hook bug" (getf receipt :decision-note))
                  "the receipt records why no decision was made"))
      (unregister-tool "test-debug-hooked"))))

(define-condition test-debug-serious (serious-condition) ())

(deftest non-error-conditions-pass-through-the-debugger ()
  (with-debugger-fixture ()
    (define-tool test-debug-serious (args) (:description "signals a non-error")
      (signal 'test-debug-serious) "unreached")
    (unwind-protect
         (progn
           (check-equal (handler-case (call-tool "test-debug-serious" (jobj))
                          (test-debug-serious () :passed-through))
                        :passed-through)
           (check-equal (list-failure-receipts) nil "nothing was journaled"))
      (unregister-tool "test-debug-serious"))))

(deftest agent-can-set-and-clear-a-retry-policy ()
  (let ((calls 0))
    (define-tool test-debug-policy (args) (:description "fails once")
      (if (< (incf calls) 2) (error "first call fails") "second call works"))
    (with-debugger-fixture ()
      (unwind-protect
           (progn
             (check (search "retried automatically" (call-tool "set-failure-recovery"
                                                                (jobj "tool" "test-debug-policy" "action" "retry"))))
             (check (gethash (component-id :recovery-policy "test-debug-policy") *components*))
             (check (search "test-debug-policy: retry" (call-tool "list-failures" (jobj))))
             (check-equal (call-tool "test-debug-policy" (jobj)) "second call works")
             (check (search "Error running"
                            (call-tool "set-failure-recovery" (jobj "tool" "nope" "action" "retry")))
                    "unknown tools are refused")
             (call-tool "set-failure-recovery" (jobj "tool" "test-debug-policy" "action" "abort"))
             (setf calls 0)
             (check (search "Error running test-debug-policy" (call-tool "test-debug-policy" (jobj)))
                    "clearing the policy restores abort"))
        (remhash "test-debug-policy" *failure-recovery-policies*)
        (unregister-tool "test-debug-policy")))))

(deftest failure-ids-cannot-escape-the-receipt-directory ()
  (check (not (safe-failure-id-p "../etc/passwd")))
  (check (not (safe-failure-id-p "")))
  (check (safe-failure-id-p "abc-123_X"))
  (check (search "id must be" (call-tool "inspect-failure" (jobj "id" "../../x")))))
