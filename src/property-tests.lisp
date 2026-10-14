;;;; property-tests.lisp -- property-based tests of Lisp functions, their
;;;; generators taken from the functions' declared types.
;;;;
;;;; cl-agent's quality gate asks every function for a type claim (DEFUN* or
;;;; DECLAIM FTYPE), and SBCL keeps it: (sb-int:info :function :type NAME).
;;;; So any such function can be fuzzed with no setup -- PROPERTY-TEST calls
;;;; it with arguments generated from its argument types, growing in size
;;;; trial by trial (as QuickCheck does), and checks on every trial that
;;;;   - it signals no error (but those of the condition types allowed),
;;;;     and returns within the time limit;
;;;;   - every value it returns is of its declared return type;
;;;;   - each property given -- (lambda (x y) ...) of the arguments, or
;;;;     (lambda (result x y) ...) with :with-result -- holds.
;;;; A failure is then shrunk to a smallest example (integers toward zero,
;;;; strings and lists shorter and their elements simpler), and reported
;;;; with the seed that reproduces the run.
;;;;
;;;; Types it generates: integers (bounded, MOD, (UN)SIGNED-BYTE, FIXNUM,
;;;; BIT), floats, ratios, REAL and NUMBER, characters, strings, symbols and
;;;; keywords, lists and vectors (of a type), CONS, NULL, BOOLEAN, MEMBER,
;;;; EQL, OR, AND (the first part generates, the rest filter), T.  Others --
;;;; a class, SATISFIES -- can be given as TYPES instead.
;;;;
;;;; It calls the function for real: point it at functions without side
;;;; effects.  It never runs on its own.

(in-package :cl-agent)

(defparameter *property-test-default-trials* 100)

;;; --- reading a function's types ---

(defun declared-function-type (name)
  "NAME's declared type as (values argument-types return-type declared-p):
ARGUMENT-TYPES like a lambda list of types -- (integer string &optional t
&key (:pretty t))."
  (let* ((type (sb-int:info :function :type name))
         (spec (and type (sb-kernel:type-specifier type))))
    (if (and (consp spec) (eq (first spec) 'function))
        (values (second spec)
                (let ((return (third spec)))
                  (if (and (consp return) (eq (first return) 'values))
                      ;; (VALUES INTEGER &OPTIONAL) or (VALUES INTEGER &REST T): the fixed ones.
                      (remove '&optional (subseq (rest return) 0 (position '&rest (rest return))))
                      (list return)))
                (eq (sb-int:info :function :where-from name) :declared))
        (values nil (list t) nil))))

(defun required-argument-types (argument-types)
  "The types of the required (and optional) arguments, from ARGUMENT-TYPES."
  (loop for type in argument-types
        until (member type '(&key &rest &allow-other-keys))
        unless (eq type '&optional) collect type))

;;; --- generating ---

(defvar *pbt-random* (make-random-state t))

(defun pbt-random (n) (if (plusp n) (random n *pbt-random*) 0))

(defun pbt-integer (low high size)
  "An integer between LOW and HIGH (either NIL for unbounded), small when
SIZE is."
  (let* ((reach (max 1 (* 2 (expt 2 (min 62 (floor size 2))))))
         (low* (or low (- reach)))
         (high* (or high reach)))
    (when (> low* high*) (error 'type-error :datum low :expected-type `(integer ,low ,high)))
    ;; Keep near zero (or the low end) for small sizes.
    (let ((low* (if (and low high) low* (max low* (- (min reach (abs low*))))))
          (high* (if (and low high) high* (min high* (max low* reach)))))
      (+ low* (pbt-random (1+ (- high* low*)))))))

(defun pbt-character ()
  (let ((roll (pbt-random 10)))
    (cond ((< roll 6) (char "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" (pbt-random 62)))
          ((< roll 8) (char " -_.,;:()[]{}\"'\\/#@!?" (pbt-random 21)))
          ((< roll 9) (code-char (+ 160 (pbt-random 400))))      ; accented, symbols
          (t (char (format nil "~c~c~c" #\Newline #\Tab (code-char 0)) (pbt-random 3))))))

(defun pbt-length (size) (pbt-random (1+ (min 64 size))))

(defun integer-type-bounds (type)
  "The bounds of integer TYPE as (values low high), or NIL when it is no
integer type."
  (let ((head (if (consp type) (first type) type))
        (args (if (consp type) (rest type) '())))
    (flet ((bound (x) (if (or (null x) (eq x '*)) nil (if (consp x) (first x) x))))
      (case head
        ((integer) (values t (bound (first args)) (bound (second args))))
        ((mod) (values t 0 (1- (first args))))
        ((unsigned-byte) (values t 0 (if (and args (integerp (first args))) (1- (expt 2 (first args))) nil)))
        ((signed-byte) (if (and args (integerp (first args)))
                           (values t (- (expt 2 (1- (first args)))) (1- (expt 2 (1- (first args)))))
                           (values t nil nil)))
        ((fixnum) (values t most-negative-fixnum most-positive-fixnum))
        ((bit) (values t 0 1))
        (t nil)))))

(defun generate-value (type size)
  "A value of TYPE (a type specifier), of about SIZE.  Signals an error
for a type it cannot generate."
  (multiple-value-bind (integer-p low high) (integer-type-bounds type)
    (when integer-p (return-from generate-value (pbt-integer low high size))))
  (let ((head (if (consp type) (first type) type))
        (args (if (consp type) (rest type) '())))
    (case head
      ((t) (generate-value (nth (pbt-random 6) '(integer string symbol (list integer) character null)) size))
      ((null) nil)
      ((boolean) (zerop (pbt-random 2)))
      ((eql) (first args))
      ((member) (nth (pbt-random (length args)) args))
      ((or) (generate-value (nth (pbt-random (length args)) args) size))
      ((and)
       (loop repeat 100
             for value = (generate-value (first args) size)
             when (typep value type) return value
             finally (error "Could not generate a value of ~s by filtering." type)))
      ((character base-char standard-char) (if (eq head 'standard-char)
                                                (char "abcxyzABC012 .-" (pbt-random 16))
                                                (pbt-character)))
      ((string simple-string base-string simple-base-string)
       (let ((length (if (and args (integerp (first args))) (first args) (pbt-length size))))
         (coerce (loop repeat length collect (if (member head '(base-string simple-base-string))
                                                  (char "abcdefghij " (pbt-random 11))
                                                  (pbt-character)))
                 'string)))
      ((keyword) (intern (string-upcase (generate-value '(string 3) size)) :keyword))
      ((symbol) (if (zerop (pbt-random 4)) nil (intern (format nil "PBT-~d" (pbt-random (+ 1 size))) :keyword)))
      ((float single-float double-float short-float long-float real number rational ratio)
       (let ((n (pbt-integer nil nil size))
             (d (1+ (pbt-random (max 1 size)))))
         (case head
           ((ratio rational) (if (and (eq head 'ratio) (zerop (mod n d))) (/ (1+ (* 2 n)) 2) (/ n d)))
           ((single-float short-float) (coerce (/ n d) 'single-float))
           ((real number) (if (zerop (pbt-random 2)) n (coerce (/ n d) 'double-float)))
           (t (coerce (/ n d) 'double-float)))))
      ((list) (loop repeat (pbt-length size) collect (generate-value 't (floor size 2))))
      ((cons) (cons (generate-value (or (first args) t) (floor size 2))
                    (generate-value (if (and (second args) (not (eq (second args) '*))) (second args) '(list)) (floor size 2))))
      ((vector simple-vector array simple-array)
       (let ((element (if (and args (not (eq (first args) '*))) (first args) t)))
         (coerce (loop repeat (pbt-length size) collect (generate-value element (floor size 2))) 'vector)))
      (t (error "Cannot generate a ~s: give its arguments' types (types), e.g. as simpler types." type)))))

;;; --- shrinking ---

(defun shrink-candidates (value)
  "Simpler values to try in VALUE's place, simplest first."
  (typecase value
    (integer (remove-duplicates (remove value (list 0 (truncate value 2) (- value (signum value)) (abs value)))))
    (string (append (and (plusp (length value)) (list ""))
                    (loop for i below (min 16 (length value))
                          collect (concatenate 'string (subseq value 0 i) (subseq value (1+ i))))
                    (let ((plain (substitute-if #\a (lambda (c) (not (alphanumericp c))) value)))
                      (and (string/= plain value) (list plain)))))
    (cons (append (list nil)
                  (loop for i below (min 16 (length value)) collect (append (subseq value 0 i) (nthcdr (1+ i) value)))
                  (loop for element in value for i from 0 repeat 8
                        append (mapcar (lambda (simpler) (append (subseq value 0 i) (list simpler) (nthcdr (1+ i) value)))
                                       (subseq (shrink-candidates element) 0 (min 2 (length (shrink-candidates element))))))))
    (vector (mapcar (lambda (list) (coerce list 'vector)) (shrink-candidates (coerce value 'list))))
    (ratio (list (truncate value)))
    (float (remove-duplicates (remove value (list 0.0d0 (coerce (truncate value) (type-of value))))))
    (t '())))

(defun shrink-arguments (arguments fails-p &key (budget 400))
  "ARGUMENTS made as simple as they can be while (FAILS-P arguments) stays
true.  Returns (values arguments steps)."
  (let ((steps 0))
    (loop
      (let ((simpler
              (loop for i below (length arguments)
                    thereis (loop for candidate in (shrink-candidates (nth i arguments))
                                  for trial = (append (subseq arguments 0 i) (list candidate) (nthcdr (1+ i) arguments))
                                  do (decf budget)
                                  when (minusp budget) return nil
                                  when (funcall fails-p trial) return trial))))
        (if simpler
            (setf arguments simpler steps (1+ steps))
            (return (values arguments steps)))))))

;;; --- running ---

(defun one-line (text)
  "TEXT with each run of whitespace a single space."
  (format nil "~{~a~^ ~}" (remove "" (uiop:split-string text :separator '(#\Space #\Newline #\Tab #\Return))
                                  :test #'string=)))

(defun property-trial (function arguments return-types properties allowed-errors seconds)
  "Call FUNCTION on ARGUMENTS once and judge it.  Returns NIL when it
passed, else a description of how it failed."
  (handler-case
      (let ((values (sb-ext:with-timeout seconds
                      (multiple-value-list (apply function arguments)))))
        (or (loop for type in return-types
                  for value in values
                  for i from 0
                  unless (or (member type '(* t &rest)) (typep value type))
                    return (format nil "returned ~s, which is not of its declared type ~(~s~)~@[ (value ~d)~]"
                                   value type (and (plusp i) (1+ i))))
            (loop for (source . property) in properties
                  unless (ignore-errors (apply property (if (getf (rest source) :with-result)
                                                            (cons (first values) arguments)
                                                            arguments)))
                    return (format nil "returned ~s, and the property ~a does not hold" (first values) (first source)))))
    (sb-ext:timeout () (format nil "did not return within ~a second~:p" seconds))
    (error (condition)
      (unless (some (lambda (type) (typep condition type)) allowed-errors)
        ;; One line: SBCL's reports break lines and indent.
        (format nil "signalled ~a: ~a" (type-of condition) (first-line (one-line (princ-to-string condition)) 240))))))

(defun run-property-test (name &key (trials *property-test-default-trials*) seed types properties
                                     allowed-errors (seconds 2))
  "Fuzz function NAME (a symbol).  TYPES overrides its argument types;
PROPERTIES are (source . function); ALLOWED-ERRORS condition types.
Returns a plist (:passed :trials :failure :arguments :original :steps
:seed :argument-types :return-types :declared)."
  (unless (fboundp name) (error "~s is not a function." name))
  (multiple-value-bind (argument-types return-types declared) (declared-function-type name)
    (unless (or types declared)
      (error "~(~s~) has no declared types (DEFUN* or DECLAIM FTYPE): give its arguments' types as types." name))
    (let* ((types (or types (required-argument-types argument-types)))
           (seed (or seed (random (expt 2 31) (make-random-state t))))
           (*pbt-random* (sb-ext:seed-random-state seed))
           (function (fdefinition name)))
      (flet ((fails (arguments) (property-trial function arguments return-types properties allowed-errors seconds)))
        (loop for trial from 1 to trials
              do (let* ((size (floor (* 100 trial) trials))
                        (arguments (mapcar (lambda (type) (generate-value type size)) types))
                        (failure (fails arguments)))
                   (when failure
                     (multiple-value-bind (smallest steps) (shrink-arguments arguments #'fails)
                       (return-from run-property-test
                         (list :passed nil :trials trial :failure (fails smallest) :arguments smallest
                               :original arguments :steps steps :seed seed :argument-types types
                               :return-types return-types :declared declared))))))
        (list :passed t :trials trials :seed seed :argument-types types :return-types return-types :declared declared)))))

(defun format-property-call (name arguments)
  (let ((*print-length* 20) (*print-level* 4) (*print-pretty* nil) (*print-case* :downcase))
    (format nil "(~s~{ ~s~})" name arguments)))

(defun format-property-test (name result)
  (destructuring-bind (&key passed trials failure arguments original steps seed argument-types return-types declared
                       &allow-other-keys) result
    (with-output-to-string (out)
      (if declared
          (format out "~(~s~): ~(~s~) -> ~(~{~s~^ ~}~)~%" name argument-types return-types)
          (format out "~(~s~): no declared types; arguments ~(~s~)~%" name argument-types))
      (if passed
          (format out "Passed ~d trial~:p (seed ~d)." trials seed)
          (progn
            (format out "FAILED on trial ~d: ~a~%  ~a~%" trials failure (format-property-call name arguments))
            (when (plusp steps)
              (format out "  (shrunk in ~d step~:p from ~a)~%" steps (format-property-call name original)))
            (format out "Seed ~d reproduces it." seed))))))

(defun read-property (text package)
  "A property from TEXT, a lambda expression, compiled in PACKAGE."
  (let* ((*package* package)
         (*read-eval* nil)
         (form (read-from-string text)))
    (unless (and (consp form) (eq (first form) 'lambda))
      (error "A property is a lambda expression: (lambda (x) ...)."))
    (compile nil form)))

(define-tool property-test (args)
    (:description "Property-based testing of a Lisp function in this image: it is called many times with arguments generated from its declared argument types (DEFUN* / DECLAIM FTYPE -- the types the quality gate asks for), growing from small to large, and every call must signal no error, return within the time limit, return values of its declared return type, and satisfy the properties you give. A failure is shrunk to a smallest example and reported with a seed that reproduces it. It calls the function for real: use it on functions without side effects.
- function: the name, e.g. \"my-pkg::parse-header\" (default package cl-agent).
- properties: lambda expressions over the arguments, e.g. [\"(lambda (s) (equal (decode (encode s)) s))\"]; with_result true passes the result first: (lambda (result s) (<= (length result) (length s))).
- types: the arguments' types to generate instead of the declared ones, e.g. \"((integer 0 100) string)\" -- also for a function with none declared.
- allowed_errors: condition types its documented errors may be, e.g. [\"parse-error\"] (any other error fails).
- trials (default 100), seed (to reproduce), seconds (per call, default 2)."
     :effects '(:process)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "function" (jobj "type" "string")
                 "properties" (jobj "type" "array" "items" (jobj "type" "string"))
                 "with_result" (jobj "type" "boolean")
                 "types" (jobj "type" "string")
                 "allowed_errors" (jobj "type" "array" "items" (jobj "type" "string"))
                 "trials" (jobj "type" "integer")
                 "seed" (jobj "type" "integer")
                 "seconds" (jobj "type" "number"))
           "required" (list "function")))
  (let* ((package (find-package :cl-agent))
         (name (let ((*package* package) (*read-eval* nil))
                 (let ((symbol (read-from-string (or (jget args "function") (error "Give the function.")))))
                   (unless (and symbol (symbolp symbol)) (error "~s is not a function name." symbol))
                   symbol)))
         (with-result (jget args "with_result"))
         (properties (mapcar (lambda (text)
                               (cons (list text :with-result with-result)
                                     (read-property text (or (symbol-package name) package))))
                             (string-list (jget args "properties"))))
         (types (let ((text (jget args "types")))
                  (and (stringp text) (plusp (length text))
                       (let ((*package* (or (symbol-package name) package)) (*read-eval* nil))
                         (let ((types (read-from-string text)))
                           (unless (listp types) (error "types is a list of type specifiers: ((integer 0 9) string)."))
                           types)))))
         (allowed (mapcar (lambda (text)
                            (let ((*package* package) (*read-eval* nil))
                              (let ((type (read-from-string text)))
                                (unless (subtypep type 'condition) (error "~s is not a condition type." type))
                                type)))
                          (string-list (jget args "allowed_errors"))))
         (trials (let ((n (jget args "trials"))) (if (and (integerp n) (plusp n)) (min n 10000) *property-test-default-trials*)))
         (seconds (let ((n (jget args "seconds"))) (if (and (realp n) (plusp n)) n 2))))
    (format-property-test name (run-property-test name :trials trials :seed (jget args "seed") :types types
                                                       :properties properties :allowed-errors allowed :seconds seconds))))
