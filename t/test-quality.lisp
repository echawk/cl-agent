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
