;;;; guard.lisp -- nothing the model does can take the agent down.
;;;;
;;;; The model runs code in this image -- eval-lisp, extensions it writes
;;;; (whose hooks then run on every turn), tools, Lisp in its replies -- and
;;;; any of it can be wrong.  The agent runs with SBCL's debugger disabled,
;;;; where a condition nobody handles, in any thread, ends the process.  So:
;;;;
;;;;   - WITH-AGENT-CODE marks code the model may have written (tool calls,
;;;;     hooks, extension loading, web routes, replies' Lisp); in it,
;;;;     exiting the image is refused.  So is exiting from any thread but
;;;;     the main one -- the agent's own shutdown happens there, and a thread
;;;;     the model starts is not WITH-AGENT-CODE.  The person still quits
;;;;     as ever: Ctrl-D, /exit.
;;;;   - WITH-TURN-GUARD runs a turn, a slash command or an input: anything
;;;;     serious that escapes it is reported (the frontend, :on-error) and
;;;;     the session carries on.  Ctrl-C (an interactive interrupt) is not
;;;;     caught: it still quits.
;;;;   - INSTALL-SURVIVAL-HOOK (from MAIN) makes the process-wide debugger
;;;;     hook keep the process alive: an unhandled condition in a thread
;;;;     other than the main one aborts that thread's current work (its
;;;;     ABORT restart, else the thread) and is logged; the main thread's
;;;;     own loop is guarded by WITH-TURN-GUARD.

(in-package :cl-agent)

(defvar *agent-code-depth* 0
  "Above zero while code the model may have written runs.")

(defmacro with-agent-code (() &body body)
  `(let ((*agent-code-depth* (1+ *agent-code-depth*)))
     ,@body))

(define-condition agent-exit-refused (error)
  ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (write-string "Exiting cl-agent from a tool, an extension or another thread is not allowed: the person quits it (Ctrl-D or /exit)." stream))))

(defun main-thread-p ()
  (eq (sb-thread:main-thread) sb-thread:*current-thread*))

(defun refuse-exit-in-agent-code (function &rest arguments)
  (if (or (plusp *agent-code-depth*) (not (main-thread-p)))
      (error 'agent-exit-refused)
      (apply function arguments)))

(sb-ext:without-package-locks
  (dolist (name '(sb-ext:exit sb-ext:quit))
    (unless (sb-int:encapsulated-p name 'cl-agent-guard)
      (sb-int:encapsulate name 'cl-agent-guard #'refuse-exit-in-agent-code))))

;;; --- conditions that escape ---

(defun interactive-interrupt-p (condition)
  (typep condition 'sb-sys:interactive-interrupt))

(defun describe-escaped-condition (condition)
  (format nil "~a: ~a" (type-of condition)
          (handler-case (let ((text (princ-to-string condition)))
                          (subseq text 0 (min 600 (length text))))
            (serious-condition () "(its report failed)"))))

(defun note-escaped-condition (condition where)
  "Log CONDITION, which escaped WHERE, and tell :on-error."
  (ignore-errors (format *error-output* "~&[cl-agent] ~a: ~a~%" where (describe-escaped-condition condition)))
  (ignore-errors (when (fboundp 'run-hook) (funcall 'run-hook :on-error condition))))

(defmacro with-turn-guard ((&key frontend (where "the turn")) &body body)
  "Run BODY; a serious condition escaping it (but Ctrl-C) is reported --
on FRONTEND too, when given -- and BODY's value is then NIL."
  (let ((block (gensym "GUARDED")) (condition (gensym "CONDITION")))
    `(block ,block
       (handler-bind ((serious-condition
                        (lambda (,condition)
                          (unless (interactive-interrupt-p ,condition)
                            (note-escaped-condition ,condition ,where)
                            ,@(when frontend
                                `((ignore-errors
                                   (ui-error ,frontend
                                             (make-condition 'simple-error
                                                             :format-control "~a failed, and was stopped: ~a"
                                                             :format-arguments (list ,where (describe-escaped-condition ,condition)))))))
                            (return-from ,block nil)))))
         ,@body))))

(defvar *previous-debugger-hook* nil)

(defun survival-debugger-hook (condition hook)
  "The process-wide debugger hook (INSTALL-SURVIVAL-HOOK)."
  (if (or (interactive-interrupt-p condition) (main-thread-p))
      ;; Ctrl-C, or the main thread's loop has let something through:
      ;; what SBCL would do.
      (if *previous-debugger-hook*
          (funcall *previous-debugger-hook* condition hook)
          (sb-debug::debugger-disabled-hook condition hook))
      (progn
        (note-escaped-condition condition (format nil "thread ~s" (ignore-errors (sb-thread:thread-name sb-thread:*current-thread*))))
        (let ((abort (find-restart 'abort condition)))
          (if abort
              (invoke-restart abort)
              (sb-thread:abort-thread))))))

(defun install-survival-hook ()
  "Make an unhandled condition in a thread other than the main one end
only that thread's work, not the process."
  (unless (eq sb-ext:*invoke-debugger-hook* 'survival-debugger-hook)
    (setf *previous-debugger-hook* sb-ext:*invoke-debugger-hook*
          sb-ext:*invoke-debugger-hook* 'survival-debugger-hook)))
