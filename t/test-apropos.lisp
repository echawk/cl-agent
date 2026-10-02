;;;; t/test-apropos.lisp -- offline tests for src/apropos.lisp. No
;;;; network, no mock data -- these search the real, already-loaded
;;;; image (plain Common Lisp, plus alexandria/serapeum/iterate/trivia,
;;;; which cl-agent.asd pulls in transitively -- see that file).

(in-package :cl-agent)

(deftest symbol-kind-recognizes-function ()
  (check-equal (symbol-kind 'car) :function))

(deftest symbol-kind-recognizes-macro ()
  (check-equal (symbol-kind 'defun) :macro))

(deftest symbol-kind-recognizes-special-operator ()
  (check-equal (symbol-kind 'if) :special-operator))

(deftest symbol-kind-recognizes-variable ()
  (check-equal (symbol-kind '*standard-output*) :variable))

(deftest symbol-kind-recognizes-class ()
  (check-equal (symbol-kind 'standard-class) :class))

(deftest symbol-kind-nil-for-plain-data-symbol ()
  ;; A keyword doesn't work for this: keywords are always BOUNDP (to
  ;; themselves). An ordinary symbol that's never been DEFUN'd,
  ;; DEFVAR'd, or DEFCLASS'd is the real "names nothing" case.
  (check-equal (symbol-kind 'a-plain-symbol-nobody-ever-defines-xyz) nil))

(deftest symbol-lambda-list-for-a-known-function ()
  ;; Don't assert exact parameter names -- SBCL's own internal argument
  ;; names for a built-in like CONS vary by version; just that a real,
  ;; 2-argument lambda list comes back.
  (check-equal (length (symbol-lambda-list 'cons :function)) 2))

(deftest symbol-lambda-list-nil-for-non-callable-kind ()
  (check-equal (symbol-lambda-list '*standard-output* :variable) nil))

(deftest lisp-apropos-matches-finds-alexandria-flatten ()
  ;; ALEXANDRIA is loaded transitively (see cl-agent.asd's header
  ;; comment) -- this doubles as a check that it's really there and
  ;; reachable by a plain, unqualified substring search.
  (check (find 'alexandria:flatten (lisp-apropos-matches "flatten") :key #'first)))

(deftest lisp-apropos-matches-restricts-to-given-package ()
  (let ((matches (lisp-apropos-matches "flatten" :package "alexandria")))
    (check matches)
    (check (every (lambda (entry) (eq (symbol-package (first entry)) (find-package :alexandria))) matches))))

(deftest lisp-apropos-matches-unknown-package-signals ()
  (check-condition error (lisp-apropos-matches "flatten" :package "not-a-real-package-xyz")))

(deftest lisp-apropos-matches-deduplicates-and-sorts ()
  (let* ((matches (lisp-apropos-matches "flatten"))
         (names (mapcar (lambda (e) (symbol-name (first e))) matches)))
    (check-equal (length names) (length (remove-duplicates matches :key #'first :test #'eq))
                 "no symbol appears twice")
    (check-equal names (sort (copy-list names) #'string<))))

(deftest lisp-apropos-text-no-match-is-graceful ()
  (let ((text (lisp-apropos-text "zzz-definitely-not-a-real-symbol-zzz")))
    (check (search "No loaded" text))))

(deftest lisp-apropos-text-includes-kind-and-lambda-list ()
  (let ((text (lisp-apropos-text "flatten" :package "alexandria")))
    (check (search "ALEXANDRIA:FLATTEN" text))
    (check (search "function" text))))

(deftest lisp-apropos-text-truncates-past-result-limit ()
  (let ((*apropos-result-limit* 2))
    (let ((text (lisp-apropos-text "a"))) ; matches far more than 2 symbols everywhere
      (check (search "more not shown" text)))))

(deftest lisp-apropos-text-bad-package-is-reported-not-an-error ()
  (check (search "error" (lisp-apropos-text "flatten" :package "not-a-real-package-xyz"))))

(deftest lisp-apropos-tool-is-registered ()
  (check (find-tool "lisp-apropos")))

(deftest lisp-apropos-tool-end-to-end ()
  (let ((result (call-tool "lisp-apropos" (jobj "query" "flatten" "package" "alexandria"))))
    (check (search "ALEXANDRIA:FLATTEN" result))))
