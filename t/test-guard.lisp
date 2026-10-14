;;;; t/test-guard.lisp -- nothing the model does can take the agent down
;;;; (guard.lisp, and the guards in tools.lisp, hooks.lisp and the turn loop).

(in-package :cl-agent)

(deftest agent-code-cannot-exit-the-image ()
  (dolist (form '("(sb-ext:exit)" "(uiop:quit 3)" "(sb-ext:exit :abort t)"))
    (let ((out (call-tool "eval-lisp" (jobj "form" form))))
      (check (search "not allowed" out) (format nil "~a: ~a" form out))))
  (let ((*error-output* (make-broadcast-stream)) (reached nil))
    (add-hook :test-point 'quitter (lambda () (uiop:quit) (setf reached t)))
    (unwind-protect (run-hook :test-point) (remove-hook :test-point 'quitter))
    (check (not reached) "a hook's exit is refused, and the hook skipped")))

(deftest runaway-recursion-in-a-tool-is-survived ()
  (let ((out (call-tool "eval-lisp" (jobj "form" "(labels ((down (n) (1+ (down n)))) (down 0))"))))
    (check (search "Error" out) out)))

(defmacro with-survival-hook (() &body body)
  `(let ((sb-ext:*invoke-debugger-hook* sb-ext:*invoke-debugger-hook*)
         (*previous-debugger-hook* *previous-debugger-hook*)
         (*error-output* (make-broadcast-stream)))
     (setf sb-ext:*invoke-debugger-hook* nil)
     (install-survival-hook)
     ;; New threads see the global value, not this binding: set it there too.
     (let ((global (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*)))
       (setf (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) 'survival-debugger-hook)
       (unwind-protect (progn ,@body)
         (setf (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) global)))))

(deftest a-failing-or-exiting-thread-ends-alone ()
  (with-survival-hook ()
    (let ((thread (bt:make-thread (lambda () (error "a thread's bug")) :name "test-failing-thread")))
      (ignore-errors (bt:join-thread thread))
      (check (not (bt:thread-alive-p thread)) "it ended; the process did not"))
    (let ((after nil))
      (bt:join-thread (bt:make-thread (lambda () (ignore-errors (sb-ext:exit)) (setf after t)) :name "test-exiting-thread"))
      (check after "exit from another thread is refused"))))

(deftest a-broken-provider-stream-ends-only-the-turn ()
  (with-noop-tool
    (let* ((frontend (make-instance 'steer-frontend))
           (session (steer-session frontend (list (lambda () (error "connection reset by peer"))))))
      (setf (session-messages session)
            (append (session-messages session) (list (list :role "user" :content "go"))))
      (check-equal (handler-case (progn (run-agent-turn session) :returned)
                     (serious-condition (c) (princ-to-string c)))
                   :returned
                   "a raw network error becomes a provider error, which the turn reports and ends on"))))

(deftest lisp-in-a-reply-cannot-run-at-read-time ()
  (let ((review (review-lisp-source "(defun f () #.(sb-ext:exit))")))
    (check (getf review :compile-failure-p) "refused, not run")))

(deftest a-route-that-blows-up-is-a-500 ()
  (with-test-web-frontend (frontend)
    (define-web-route test-recursion (:path "/api/test/recursion")
      (labels ((down (n) (1+ (down n)))) (down 0)))
    (unwind-protect
         (check-equal (nth-value 1 (web-get frontend "/api/test/recursion")) 500)
      (remhash "test-recursion" *web-routes*))))

(deftest eval-lisp-gives-up-on-a-form-that-never-returns ()
  (let ((*eval-lisp-seconds* 1))
    (check (search "timed out" (call-tool "eval-lisp" (jobj "form" "(loop)"))))))

(deftest an-extension-whose-hook-would-break-every-turn-is-refused ()
  (let ((out (call-tool "write-extension"
                        (jobj "filename" "test-bad-hook.lisp"
                              "source" "(in-package :cl-agent)
(declaim (ftype (function (list) (values list &optional)) test-bad-paths-hook))
(defun test-bad-paths-hook (ctx)
  (getf (getf ctx :arguments) \"path\")
  ctx)
(add-hook :after-tool-call 'test-bad-paths-hook #'test-bad-paths-hook)
"))))
    (unwind-protect
         (progn
           (check (search "failed on a sample call" out) out)
           (check (search "jget" out) "and says how to read tool arguments")
           (check (not (assoc 'test-bad-paths-hook (gethash :after-tool-call *hooks*))) "nothing left installed"))
      (remove-hook :after-tool-call 'test-bad-paths-hook))))
