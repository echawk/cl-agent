;;;; t/test-property-tests.lisp -- property-based tests from declared types
;;;; (property-tests.lisp).

(in-package :cl-agent)

(defun* (pbt-add -> integer) ((a integer) (b (integer 0 10))) (+ a b))
(defun* (pbt-bad-abs -> (integer 0)) ((x integer)) (if (> x 100) x (if (< x 0) (if (< x -50) (- x) x) x)))
(defun* (pbt-head -> t) ((l list)) (if l (car l) (error "The list is empty.")))
(defun* (pbt-spin -> integer) ((n integer)) (loop (setf n (1+ n))))
(defun* (pbt-encode -> string) ((s string)) (reverse s))
(defun pbt-undeclared (x) (* 2 x))

(defun pbt (name &rest args) (call-tool "property-test" (apply #'jobj "function" name args)))

(deftest property-tests-pass-what-holds ()
  (let ((out (pbt "pbt-add" "properties" (list "(lambda (a b) (= (pbt-add a b) (+ b a)))"))))
    (check (search "Passed 100 trials" out) out))
  (check (search "(integer (mod 11)) -> integer" (pbt "pbt-add" "trials" 5)) "says the declared types")
  (check (search "Passed" (pbt "pbt-encode" "properties" (list "(lambda (s) (equal (pbt-encode (pbt-encode s)) s))"))))
  (check (search "Passed" (pbt "pbt-encode" "with_result" t "properties" (list "(lambda (r s) (= (length r) (length s)))")))))

(deftest property-tests-find-and-shrink-failures ()
  (let ((out (pbt "pbt-bad-abs" "seed" 7)))
    (check (search "FAILED" out) out)
    (check (search "TYPE-ERROR: The value -1 is not of type" out) "SBCL checks the declared return type")
    (check (search "(pbt-bad-abs -1)" out) "shrunk to the smallest negative")
    (check (search "Seed 7 reproduces it" out))
    (check-equal (pbt "pbt-bad-abs" "seed" 7) out "the seed reproduces the run"))
  (let ((out (pbt "pbt-head")))
    (check (search "signalled SIMPLE-ERROR: The list is empty." out) out)
    (check (search "(pbt-head nil)" out) "shrunk to the empty list"))
  (check (search "Passed" (pbt "pbt-head" "allowed_errors" (list "simple-error"))) "allowed errors pass")
  (check (search "did not return within 0.2 seconds" (pbt "pbt-spin" "seconds" 0.2 "trials" 2)))
  (check (search "property (lambda (s) (equal s (reverse s))) does not hold"
                 (pbt "pbt-encode" "properties" (list "(lambda (s) (equal s (reverse s)))")))))

(deftest property-tests-of-undeclared-functions-take-types ()
  (check (search "has no declared types" (pbt "pbt-undeclared")) "no type: says to give one")
  (check (search "Passed" (pbt "pbt-undeclared" "types" "((integer -5 5))" "with_result" t
                               "properties" (list "(lambda (r x) (declare (ignore x)) (evenp r))")))))

(deftest values-are-generated-from-types ()
  (let ((*pbt-random* (sb-ext:seed-random-state 1)))
    (dolist (type '((integer 3 9) (mod 4) bit string (string 4) character keyword (or null string)
                    (member :a :b) (eql 5) list (vector integer) double-float ratio (cons integer integer)
                    (and integer (satisfies evenp)) boolean))
      (dotimes (i 20)
        (let ((value (generate-value type (* 5 i))))
          (check (typep value type) (format nil "~s is a ~s" value type)))))))
