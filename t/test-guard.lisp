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

(deftest no-non-local-exit-leaves-a-tool-call ()
  (dolist (form '("(abort)" "(continue)" "(invoke-restart (car (last (compute-restarts))))"
                  "(throw 'sb-impl::%end-of-the-world 0)"))
    (let ((out (call-tool "eval-lisp" (jobj "form" form))))
      (check (search "non-local exit" out) (format nil "~a: ~a" form out))))
  (check (search "Interactive interrupt"
                 (call-tool "eval-lisp" (jobj "form" "(error 'sb-sys:interactive-interrupt)")))
         "a Ctrl-C the code makes up itself is an error like any other, not a quit")
  (check (search "cannot be terminated"
                 (call-tool "eval-lisp" (jobj "form" "(sb-thread:terminate-thread (sb-thread:main-thread))")))
         "the agent's own threads cannot be ended from code"))

(deftest no-non-local-exit-leaves-a-hook ()
  (let ((*error-output* (make-broadcast-stream)))
    (add-hook :test-point 'aborter (lambda () (abort)))
    (add-hook :test-chain 'thrower (lambda (value) (declare (ignore value)) (throw 'nowhere-in-particular 1)))
    (unwind-protect
         (progn
           (check-equal (multiple-value-list (run-hook :test-point)) nil "the hook is skipped, the caller goes on")
           (check-equal (run-hook-chain :test-chain "value") "value" "the value goes on as it was"))
      (remove-hook :test-point 'aborter)
      (remove-hook :test-chain 'thrower))))

(deftest eval-lisp-output-is-the-models-not-the-terminals ()
  (let ((out (call-tool "eval-lisp" (jobj "form" "(progn (format t \"printed here~%\") (close *standard-output*) :done)"))))
    (check (search "printed here" out) "what the form prints comes back to the model")
    (check (open-stream-p *standard-output*) "and the agent's own output stream is untouched"))
  (check (search "end of file" (call-tool "eval-lisp" (jobj "form" "(read-line)")))
         "nothing to read: it does not wait on the terminal"))

(deftest a-guard-the-model-removes-is-put-back ()
  (with-survival-hook ()
    (let ((*survival-hook-installed* t))
      (call-tool "eval-lisp" (jobj "form" "(progn (setf (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) nil) (sb-int:unencapsulate 'sb-ext:exit 'cl-agent-guard) :gone)"))
      (check (eq (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) 'survival-debugger-hook)
             "the debugger hook is back")
      (check (sb-int:encapsulated-p 'sb-ext:exit 'cl-agent-guard) "and so is the exit guard"))))

(defclass exit-at-prompt-frontend (steer-frontend)
  ((inputs :initarg :inputs :accessor exit-at-prompt-inputs)))

(defmethod ui-prompt-input ((frontend exit-at-prompt-frontend))
  (let ((next (pop (exit-at-prompt-inputs frontend))))
    ;; Something unwinding the loop while it waits for input -- as a thread
    ;; the model started could make it.
    (case next
      (:abort (abort))
      (:throw (throw 'sb-impl::%end-of-the-world 0))
      (t next))))

(deftest the-session-loop-survives-an-exit-at-the-prompt ()
  (with-noop-tool
    (let* ((frontend (make-instance 'exit-at-prompt-frontend :inputs (list "first" :abort :throw "second")))
           (session (steer-session frontend
                                   (list (lambda () (list :role "assistant" :content "one" :tool-calls nil))
                                         (lambda () (list :role "assistant" :content "two" :tool-calls nil)))))
           (*error-output* (make-broadcast-stream)))
      (run-repl session :primary nil)
      (check-equal (length (steer-seen (session-provider session))) 2
                   "after exits at the prompt, the session still answered the next message"))))

(deftest runaway-allocation-is-stopped-before-the-heap-runs-out ()
  (sb-ext:gc :full t)
  (let ((limit *agent-memory-limit*))
    ;; SETF: the after-GC hook may run in another thread.  A limit a little
    ;; above what is in use now, so the test allocates tens of MB, not GBs.
    (setf *agent-memory-limit* (+ (/ (sb-kernel:dynamic-usage) (sb-ext:dynamic-space-size)) 0.05))
    (unwind-protect
         (progn
           (install-memory-guard)
           (let ((out (call-tool "eval-lisp" (jobj "form" "(let ((a nil)) (loop repeat 2000000 do (push (make-string 1000) a)) (length a))"))))
             (check (search "heap was" out) out))
           ;; What it built is garbage now, though the heap still counts it
           ;; until a full collection: ordinary code is not stopped for it.
           (sleep 1.5)
           (check (search "2" (call-tool "eval-lisp" (jobj "form" "(+ 1 1)"))) "the next call runs"))
      (setf *agent-memory-limit* limit)
      (sb-ext:gc :full t))))

(deftest threads-agent-code-starts-are-agent-code-but-the-agents-own-are-not ()
  (flet ((depth-in-new-thread () (bt:join-thread (bt:make-thread (lambda () *agent-code-depth*)))))
    (check-equal (with-agent-code () (depth-in-new-thread)) 1 "a thread the model's code starts is agent code")
    (check-equal (with-agent-code () (as-agent-itself (depth-in-new-thread))) 0
                 "a service thread the agent starts from there is not (Lem's editor, its display server)")))
