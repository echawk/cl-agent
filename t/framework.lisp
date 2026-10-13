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

(defun under-directory-p (path directory)
  (let ((path (uiop:ensure-directory-pathname path)))
    (or (uiop:pathname-equal path directory)
        (uiop:subpathp path (uiop:ensure-directory-pathname directory)))))

(defun call-with-test-state (function)
  "Call FUNCTION with *CONFIG-DIRECTORY*'s global value -- the one every
thread sees, web request handlers and subagent workers included -- set to
the run's own directory, and restore it afterwards.

LEM_HOME points into it too, and the hosted Lem is stopped before and after,
so it never reads or writes the user's own Lem directory.

The directory is CL_AGENT_CONFIG_DIR (`make test` points it at a fresh
temporary directory and removes it afterwards), else a new temporary
directory removed here.  Never the user's ~/.config/cl-agent/: tests create
sessions, tasks and extensions by the hundred."
  (let* ((saved *config-directory*)
         (env (uiop:getenv "CL_AGENT_CONFIG_DIR"))
         (own (not (and env (plusp (length env)))))
         (root (if own
                   (merge-pathnames (format nil "cl-agent-test-~36r/" (random (expt 36 8)))
                                    (uiop:temporary-directory))
                   (default-config-directory))))
    (when (under-directory-p root (user-config-directory))
      (error "Refusing to run tests with CL_AGENT_CONFIG_DIR=~a: it is the user's own ~
              cl-agent directory.  Point it at a temporary directory." root))
    (ensure-directories-exist root)
    ;; The hosted Lem (src/lem/) reads its init file and writes config.lisp
    ;; and history under LEM_HOME: never the user's own Lem directory.
    (let ((saved-lem-home (uiop:getenv "LEM_HOME"))
          (lem-home (merge-pathnames "lem-home/" root)))
      (ensure-directories-exist lem-home)
      (unwind-protect
           (progn (setf *config-directory* root)
                  (lem-host-stop)
                  (setf (uiop:getenv "LEM_HOME") (uiop:native-namestring lem-home))
                  (funcall function root))
        (lem-host-stop)
        (if saved-lem-home
            (setf (uiop:getenv "LEM_HOME") saved-lem-home)
            (sb-posix:unsetenv "LEM_HOME"))
        (setf *config-directory* saved)
        (when own (ignore-errors (uiop:delete-directory-tree root :validate t)))))))

(defmacro with-test-state ((&optional (root (gensym "ROOT"))) &body body)
  "Run BODY with every thread's cl-agent state under a temporary directory
ROOT (see CALL-WITH-TEST-STATE)."
  `(call-with-test-state (lambda (,root) (declare (ignorable ,root)) ,@body)))

(defun run-all-tests ()
  "Run every registered test, print a summary, and return T iff
everything passed. Called by `(asdf:test-op :cl-agent)` / `make test`;
exits the process with status 1 on any failure so CI (or a human
running make) can tell at a glance.  Each test gets a fresh state
directory under the run's (see CALL-WITH-TEST-STATE)."
  (setf *pass-count* 0 *fail-count* 0)
  (with-test-state (root)
    (format t "~&State directory: ~a~%" (uiop:native-namestring root))
    (loop for test in *tests*
          for index from 1
          do (let ((*current-test* (car test)))
               ;; SETF, not LET: threads a test starts must see it too.
               (setf *config-directory* (merge-pathnames (format nil "test-~d/" index) root))
               (format t "~&* ~a~%" (car test))
               (unwind-protect
                    (handler-case (funcall (cdr test))
                      (error (c) (incf *fail-count*) (format t "~&  ERROR: ~a~%" c)))
                 (ignore-errors (uiop:delete-directory-tree *config-directory* :validate t))
                 (setf *config-directory* root)))))
  (format t "~&~%~d passed, ~d failed~%" *pass-count* *fail-count*)
  (let ((ok (zerop *fail-count*)))
    (unless ok (uiop:quit 1))
    ok))
