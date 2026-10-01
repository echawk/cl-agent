;;;; t/test-clspec.lisp -- offline tests for src/clspec.lisp. These
;;;; read the real, committed data/cl-spec.sdoc (no network, no mock
;;;; data needed -- it's just a file), so they double as a check that
;;;; the committed data file is well-formed and that the lookups this
;;;; feature exists for actually work against it.

(in-package :cl-agent)

(deftest clspec-data-file-is-present-and-parses ()
  (check (clspec-data-pathname) "data/cl-spec.sdoc is found by CLSPEC-DATA-PATHNAME")
  (check (clspec-ensure-index) "the sdoc file parses into a non-empty index"))

(deftest clspec-lookup-simple-function ()
  (let ((text (lookup-cl-spec-text "format")))
    (check (search "Function" text))
    (check (search "Syntax" text))))

(deftest clspec-lookup-is-case-insensitive ()
  (check-equal (lookup-cl-spec-text "CAR") (lookup-cl-spec-text "car")))

(deftest clspec-lookup-multi-name-entry-covers-every-alias ()
  ;; car/cdr/caar/.../cddddr are one :COM entry (see output-spec.md's
  ;; :def "Multi" forms); looking up any alias should find it, and the
  ;; rendered signature should mention the specific alias asked for.
  (let ((text (lookup-cl-spec-text "cddddr")))
    (check (search "Accessor" text))
    (check (search "cddddr" text))))

(deftest clspec-lookup-name-with-multiple-entries ()
  ;; "list" is both a function and a system class (output-spec.md's
  ;; own example of this); both should come back, separated.
  (let ((text (lookup-cl-spec-text "list")))
    (check (search "Function" text))
    (check (search "System Class" text))
    (check (search "---" text) "multiple entries are visibly separated")))

(deftest clspec-lookup-unknown-name-suggests-candidates ()
  (let ((text (lookup-cl-spec-text "defma")))
    (check (search "No exact match" text))
    (check (search "DEFMACRO" text))))

(deftest clspec-lookup-nonsense-name-is-graceful ()
  (let ((text (lookup-cl-spec-text "zzz-not-a-real-symbol-zzz")))
    (check (search "No match" text))))

(deftest clspec-lookup-part-filter-narrows-output ()
  (let ((full (lookup-cl-spec-text "loop"))
        (examples-only (lookup-cl-spec-text "loop" :part "examples")))
    (check (> (length full) (length examples-only)) "filtering to one part shortens the result")
    (check (search "Examples" examples-only))
    (check (not (search "Exceptional Situations" examples-only))
           "other parts are excluded when :part is given")))

(deftest clspec-missing-data-file-is-reported-not-an-error ()
  ;; Simulate "no data file anywhere" by temporarily replacing
  ;; CLSPEC-DATA-PATHNAME's definition (the real one has no way to
  ;; fail in this dev environment, since data/cl-spec.sdoc genuinely
  ;; exists) rather than signalling -- LOOKUP-CL-SPEC-TEXT must still
  ;; return a plain explanatory string, not an error.
  (let ((original (symbol-function 'clspec-data-pathname))
        (*clspec-index* nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'clspec-data-pathname) (lambda () nil))
           (check-equal (clspec-ensure-index) nil)
           (check (stringp (lookup-cl-spec-text "car")))
           (check (search "isn't available" (lookup-cl-spec-text "car"))))
      (setf (symbol-function 'clspec-data-pathname) original))))

(deftest lookup-cl-spec-tool-is-registered ()
  (check (find-tool "lookup-cl-spec")))

(deftest lookup-cl-spec-tool-end-to-end ()
  (let ((result (call-tool "lookup-cl-spec" (jobj "name" "defun"))))
    (check (search "Macro" result))
    (check (search "Syntax" result))))
