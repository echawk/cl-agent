(in-package :cl-agent)

(deftest review-lisp-reports-mallet-score ()
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(declaim (ftype (function (integer) integer) typed-id))~%(defun typed-id (x) (if x x))~%"))))
    (check (< 0 (getf review :score)) "Mallet findings contribute to the score")
    (check (getf review :violations) "known missing-else smell is reported")))

(deftest review-lisp-detects-missing-type-claim ()
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(defun untyped-review-fixture (x) x)~%"))))
    (check (member "UNTYPED-REVIEW-FIXTURE" (getf review :missing-type-claims)
                   :test #'string=))))

(deftest review-lisp-accepts-declaim-type-claim ()
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(declaim (ftype (function (t) t) typed-review-fixture))~%(defun typed-review-fixture (x) x)~%"))))
    (check-equal (getf review :missing-type-claims) nil)
    (check-equal (getf review :compile-failure-p) nil)))

(deftest review-lisp-accepts-defstar-type-claim ()
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(defun* (typed-star-fixture -> integer) ((x integer)) x)~%"))))
    (check-equal (getf review :missing-type-claims) nil)
    (check-equal (getf review :compile-failure-p) nil)))

(deftest review-lisp-reports-compiler-failure ()
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(declaim (ftype (function () integer) broken-review-fixture))~%(defun broken-review-fixture () (let ((x 1))~%"))))
    (check (getf review :compile-failure-p))
    (check (< 0 (length (getf review :compiler-diagnostics))))))

(deftest review-lisp-tool-is-registered ()
  (check (find-tool "review-lisp")))

(deftest lisp-quality-tools-analyze-existing-files-without-artifacts ()
  (let ((path (merge-pathnames "cl-agent-quality-file-test.lisp" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "(in-package :cl-agent)~%(defun quality-file-fixture (x) x)~%"))
           (let ((review (call-tool "review-lisp" (jobj "path" (namestring path)))))
             (check (search "quality-file-fixture" review :test #'char-equal))
             (check (not (probe-file (compile-file-pathname path)))
                    "file review does not leave a FASL beside the target"))
           (check-equal (call-tool "check-parens" (jobj "path" (namestring path)))
                        "Parentheses are balanced.")
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "(defun missing-close ()~%  1~%"))
           (check (search "Unbalanced parentheses"
                          (call-tool "check-parens" (jobj "path" (namestring path))))))
      (when (probe-file path) (delete-file path)))))

(deftest lisp-quality-tools-require-one-input-form ()
  (check (search "requires exactly one" (call-tool "review-lisp" (jobj))))
  (check (search "not both"
                 (call-tool "check-parens" (jobj "source" "()" "path" "some.lisp")))))

(deftest common-lisp-fences-are-extracted-selectively ()
  (check-equal
   (extract-common-lisp-code-blocks
    (format nil "text~%```common-lisp~%(+ 1 2)~%```~%```python~%print(3)~%```~%```cl~%(+ 4 5)~%```~%"))
   (list (format nil "(+ 1 2)~%") (format nil "(+ 4 5)~%"))))

(deftest assistant-common-lisp-trailing-whitespace-is-normalized ()
  (let ((content (format nil "```lisp~%(defun tidy () 42)   ~%```~%Text with trailing spaces stays untouched.   ~%")))
    (check-equal
     (normalize-assistant-common-lisp content)
     (format nil "```lisp~%(DEFUN TIDY () 42)~%```~%Text with trailing spaces stays untouched.   ~%"))))

(deftest malformed-common-lisp-is-not-pretty-printed ()
  (let ((content (format nil "```lisp~%(defun broken (x)   ~%```")))
    (check-equal (normalize-assistant-common-lisp content)
                 (format nil "```lisp~%(defun broken (x)~%```"))))

(deftest assistant-common-lisp-review-keeps-type-claims-advisory ()
  (let ((reviews
          (review-assistant-common-lisp
           (format nil "```lisp~%(in-package :cl-agent)~%(defun reply-fixture (x) x)~%```~%"))))
    (check-equal (length reviews) 1)
    (check (member "REPLY-FIXTURE" (getf (first reviews) :missing-type-claims)
                   :test #'string=))
    (check (not (lisp-review-needs-revision-p (first reviews))))))

(deftest load-asdf-system-tool-is-registered-and-loads-known-system ()
  (check (find-tool "load-asdf-system"))
  (check (search "Loaded ASDF system alexandria"
                 (call-tool "load-asdf-system" (jobj "system" "alexandria")))))

;;; Reviewing any Lisp: other projects' files, snippets, and the agent's own
;;; source, without the compile check changing the running image.

(deftest review-lisp-never-changes-the-running-image ()
  (eval '(defmacro cl-agent::review-test-macro () :original))
  (let ((review (review-lisp-source
                 (format nil "(in-package :cl-agent)~%(defmacro review-test-macro () :replaced)~%~
                              (defmacro review-test-new-macro () 1)~%(defpackage :review-test-package (:use :cl))~%~
                              (defstruct review-test-struct a)~%"))))
    (check (not (getf review :compile-failure-p)))
    (check-equal (macroexpand '(cl-agent::review-test-macro)) :original "a changed macro is put back")
    (check (null (macro-function 'cl-agent::review-test-new-macro)) "a new macro is removed")
    (check (null (find-package :review-test-package)) "a new package is deleted")
    (check (null (find-class 'cl-agent::review-test-struct nil)) "a new structure is forgotten")))

(deftest review-lisp-lints-code-whose-package-is-not-loaded ()
  (dolist (source (list (format nil "(in-package :review-absent-package)~%(defun f () 1)~%")
                        (format nil "(defun g () (review-absent-package:thing))~%")))
    (let ((review (review-lisp-source source)))
      (check (not (getf review :compile-failure-p)) "not a failed compilation")
      (check (search "REVIEW-ABSENT-PACKAGE" (getf review :compile-skipped)))
      (check (< (getf review :score) 1000))
      (check (search "not checked" (format-lisp-review review))))))

(deftest review-lisp-compiles-snippets-in-a-given-package ()
  (let ((snippet "(defun review-probe () (lisp-name-match :prefix \"a\" \"ab\"))"))
    (check (null (getf (review-lisp-source snippet :package "cl-agent") :compiler-diagnostics))
           "cl-agent's functions are known")
    (let ((*package* (find-package :cl-user)))
      (check (some (lambda (d) (search "LISP-NAME-MATCH" (string-upcase d)))
                   (getf (review-lisp-source snippet) :compiler-diagnostics))
             "elsewhere it is an undefined function"))
    (check-condition error (review-lisp-source snippet :package "no-such-package-xyz"))))

(deftest review-lisp-reviews-the-agents-own-source-by-system-path ()
  (let ((text (call-tool "review-lisp" (jobj "path" "cl-agent/src/quality.lisp"))))
    (check (search "Lisp quality score" text) text)
    (check (not (search "does not exist" text))))
  (check (search "lisp-source tool lists" (call-tool "review-lisp" (jobj "path" "cl-agent/src/nope.lisp")))))
