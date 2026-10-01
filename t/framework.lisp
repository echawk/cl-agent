;;;; t/framework.lisp -- a deliberately tiny test runner. cl-agent has
;;;; exactly one Lisp dependency per external library it actually needs
;;;; (drakma, shasht); pulling in a whole test framework for this small
;;;; a suite didn't seem worth it, and a homemade CHECK/DEFTEST is easy
;;;; enough for an extension's own tests (if it ever wants any) to copy.
;;;;
;;;; This lives in the :CL-AGENT package itself (see package.lisp's
;;;; header comment on why the whole project is one flat package)
;;;; rather than a separate test package that would have to :USE it --
;;;; that would need every symbol a test touches to be explicitly
;;;; EXPORTed, which is exactly the bookkeeping tax the flat-package
;;;; design exists to avoid. The cl-agent/tests ASDF system (see
;;;; cl-agent.asd) is still only loaded when you actually run tests, so
;;;; this adds nothing to a normal `make build`/`make run`.

(in-package :cl-agent)

(defvar *tests* nil "alist of (name . thunk), in registration order.")
(defvar *pass-count* 0)
(defvar *fail-count* 0)
(defvar *current-test* nil)

(defmacro deftest (name () &body body)
  "Register a test. NAME is a symbol, used for reporting; tests run in
the order they were DEFTEST'd (i.e. load order of the t/test-*.lisp
files, see cl-agent.asd)."
  `(setf *tests* (append (remove ',name *tests* :key #'car)
                          (list (cons ',name (lambda () ,@body))))))

(defun report-fail (description)
  (incf *fail-count*)
  (format t "~&  FAIL [~a]~@[: ~a~]~%" *current-test* description))

(defun check (value &optional description)
  "Pass if VALUE is non-NIL."
  (if value (incf *pass-count*) (report-fail description)))

(defmacro check-equal (actual expected &optional description)
  "Pass if (EQUAL ACTUAL EXPECTED). On failure, reports both, so
DESCRIPTION only needs to say what's being checked, not what went wrong."
  (let ((a (gensym)) (e (gensym)))
    `(let ((,a ,actual) (,e ,expected))
       (if (equal ,a ,e)
           (incf *pass-count*)
           (report-fail (format nil "~@[~a: ~]got ~s, expected ~s" ,description ,a ,e))))))

(defmacro check-condition (condition-type form &optional description)
  "Pass if evaluating FORM signals a condition of type CONDITION-TYPE."
  `(handler-case
       (progn ,form (report-fail (or ,description (format nil "expected ~a" ',condition-type))))
     (,condition-type () (incf *pass-count*))))

(defun run-all-tests ()
  "Run every registered test, print a summary, and return T iff
everything passed. Called by `(asdf:test-op :cl-agent)` / `make test`;
exits the process with status 1 on any failure so CI (or a human
running make) can tell at a glance."
  (setf *pass-count* 0 *fail-count* 0)
  (dolist (test *tests*)
    (let ((*current-test* (car test)))
      (format t "~&* ~a~%" (car test))
      (handler-case (funcall (cdr test))
        (error (c) (incf *fail-count*) (format t "~&  ERROR: ~a~%" c)))))
  (format t "~&~%~d passed, ~d failed~%" *pass-count* *fail-count*)
  (let ((ok (zerop *fail-count*)))
    (unless ok (uiop:quit 1))
    ok))
