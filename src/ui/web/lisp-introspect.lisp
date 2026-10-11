;;;; ui/web/lisp-introspect.lisp -- what the Lisp tab asks the image about
;;;; code, SLY-style: symbol completion (prefix, then m-v-b style
;;;; abbreviations), argument lists for the echo area (autodoc), DESCRIBE,
;;;; the HyperSpec, macroexpansion, M-. definition sources, and the
;;;; inspector behind every clickable value.  Nothing here interns a symbol
;;;; or evaluates user code except macroexpansion.

(in-package :cl-agent)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute)
         (ignore-errors (require :sb-introspect))
         (ignore-errors (require :sb-cltl2)))

(defun introspect (name &rest args)
  "Call SB-INTROSPECT's NAME on ARGS, or return NIL if it is unavailable."
  (let ((function (find-symbol name "SB-INTROSPECT")))
    (and function (fboundp function) (ignore-errors (apply function args)))))

;;; --- symbols, as written ---

(defun lisp-token-symbol (token package)
  "The existing symbol TOKEN (\"foo\", \"pkg:foo\", \"pkg::foo\", \":kw\",
\"#'foo\") names when read in PACKAGE, or NIL.  Never interns."
  (let* ((token (string-left-trim "'`#," token))
         (colon (position #\: token))
         (home (cond ((null colon) package)
                     ((zerop colon) (find-package :keyword))
                     (t (lisp-repl-find-package (subseq token 0 colon)))))
         (name (if colon (string-left-trim ":" (subseq token colon)) token)))
    (when (and home (plusp (length name)))
      (let ((name (if (and (char= (char name 0) #\|) (char= (char name (1- (length name))) #\|))
                      (subseq name 1 (1- (length name)))
                      (string-upcase name))))
        (values (find-symbol name home))))))

;;; --- completion ---

(defun whitespace-char-p (char)
  (member char '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed)))

(defun lisp-constituent-p (char)
  (not (or (member char '(#\( #\) #\' #\` #\, #\" #\;)) (whitespace-char-p char))))

(defun lisp-abbreviation-p (token name)
  "True when each dash-separated piece of TOKEN starts the matching piece
of NAME, so m-v-b abbreviates multiple-value-bind."
  (let ((pieces (uiop:split-string token :separator "-"))
        (parts (uiop:split-string name :separator "-")))
    (and (> (length pieces) 1)
         (<= (length pieces) (length parts))
         (every (lambda (piece part) (uiop:string-prefix-p (string-upcase piece) part)) pieces parts))))

(defun lisp-repl-complete (text cursor package)
  "Complete the symbol before CURSOR in TEXT, read in PACKAGE; a plist like
COMPLETE-INPUT's.  Unqualified names complete among symbols with a
definition (and package names); pkg: or pkg:: among that package's
external or all symbols; :kw among keywords.  When no name has the typed
prefix, dash abbreviations (m-v-b) are tried."
  (let* ((cursor (max 0 (min cursor (length text))))
         (start (let ((i cursor))
                  (loop while (and (> i 0) (lisp-constituent-p (char text (1- i)))) do (decf i))
                  i))
         (raw (subseq text start cursor))
         (skip (cond ((uiop:string-prefix-p "#'" raw) 2) ((uiop:string-prefix-p "#:" raw) 2) (t 0)))
         (start (+ start skip))
         (token (subseq raw skip))
         (colon (position #\: token))
         (internal-p (and colon (< (1+ colon) (length token)) (char= (char token (1+ colon)) #\:)))
         (prefix (if colon (subseq token 0 (+ colon (if internal-p 2 1))) ""))
         (name (if colon (subseq token (length prefix)) token))
         (home (cond ((null colon) package)
                     ((zerop colon) (find-package :keyword))
                     (t (lisp-repl-find-package (subseq token 0 colon)))))
         (keywordp (and colon (zerop colon)))
         (symbols nil) (abbreviations nil) (packages nil)
         (seen (make-hash-table :test 'eq)))
    (when (and home (or colon (plusp (length name))))
      (flet ((consider (symbol)
               (unless (gethash symbol seen)
                 (setf (gethash symbol seen) t)
                 (let ((sname (symbol-name symbol)))
                   (when (or colon (fboundp symbol) (boundp symbol) (find-class symbol nil)
                             (special-operator-p symbol))
                     (cond ((and (<= (length name) (length sname))
                                 (string-equal name sname :end2 (length name)))
                            (push symbol symbols))
                           ((lisp-abbreviation-p name sname)
                            (push symbol abbreviations))))))))
        (if (and colon (not internal-p) (not keywordp))
            (do-external-symbols (symbol home) (consider symbol))
            (do-symbols (symbol home) (consider symbol)))))
    (unless (or colon (zerop (length name)))
      (dolist (each (list-all-packages))
        (dolist (package-name (cons (package-name each) (package-nicknames each)))
          (when (and (<= (length name) (length package-name))
                     (string-equal name package-name :end2 (length name)))
            (pushnew (string-downcase package-name) packages :test #'string=)))))
    (let* ((chosen (or symbols abbreviations))
           (sorted (sort chosen (lambda (a b)
                                  (let ((la (length (symbol-name a))) (lb (length (symbol-name b))))
                                    (if (= la lb) (string< (symbol-name a) (symbol-name b)) (< la lb))))))
           (candidates
             (append (mapcar (lambda (symbol)
                               (let ((display (string-downcase (symbol-name symbol))))
                                 (make-completion (concatenate 'string (string-downcase prefix) display)
                                                  :display display
                                                  :doc (ignore-errors (symbol-completion-doc symbol))
                                                  :kind (if keywordp "keyword" (symbol-completion-kind symbol)))))
                             sorted)
                     (mapcar (lambda (name) (make-completion (concatenate 'string name ":") :kind "package"))
                             (sort packages #'string<)))))
      (list :start start :end cursor :token token
            :candidates (subseq candidates 0 (min (length candidates) *completion-limit*))
            :total (length candidates)
            :source (if (and abbreviations (not symbols)) "lisp-abbreviations" "lisp")))))

;;; --- autodoc: the argument list in the echo area ---

(defun lambda-list-elements (lambda-list)
  "LAMBDA-LIST's top-level elements as a proper list ((a . b) gives a &rest b)."
  (loop for tail = lambda-list then (cdr tail)
        while (consp tail) collect (car tail) into elements
        finally (return (if tail (append elements (list '&rest tail)) elements))))

(defun lambda-list-key-name (parameter)
  (let ((parameter (if (consp parameter) (first parameter) parameter)))
    (string (if (consp parameter) (first parameter) parameter))))

(defun lambda-list-current (elements index keyword)
  "Position in ELEMENTS of the parameter that argument INDEX (0-based) fills,
or, among &key parameters, the one KEYWORD (\":name\") names."
  (let ((state :required) (argument 0) (skip nil)
        (keyword (and keyword (string-left-trim ":" keyword))))
    (loop for element in elements for position from 0
          do (cond (skip (setf skip nil))
                   ((member element '(&whole &environment)) (setf skip t))
                   ((eq element '&optional) (setf state :optional))
                   ((member element '(&rest &body))
                    (when (and (member state '(:required :optional)) (>= index argument)
                               (not keyword))
                      (return (1+ position)))
                    (setf state :rest skip t))
                   ((eq element '&key) (setf state :key))
                   ((member element '(&aux)) (return nil))
                   ((eq element '&allow-other-keys))
                   ((member state '(:required :optional))
                    (when (and (= argument index) (not keyword)) (return position))
                    (incf argument))
                   ((and (eq state :key) keyword
                         (string-equal (lambda-list-key-name element) keyword))
                    (return position))))))

(defun lisp-repl-autodoc (operator index keyword package)
  "What the echo area shows inside a call to OPERATOR: a JOBJ with the
operator, its argument list (one string per element) and the position of
the argument at the cursor -- or NIL when OPERATOR names nothing callable."
  (let* ((symbol (lisp-token-symbol operator package))
         (kind (and symbol (symbol-kind symbol))))
    (when (member kind '(:function :macro :generic-function :special-operator))
      (let* ((*print-case* :downcase) (*package* package) (*print-pretty* nil)
             (lambda-list (symbol-lambda-list symbol kind))
             (elements (lambda-list-elements lambda-list))
             (syntax (and (eq kind :special-operator) (null lambda-list)
                          (special-operator-syntax symbol))))
        (jobj "operator" (string-downcase (symbol-name symbol))
              "kind" (string-downcase (symbol-name kind))
              ;; PRINC: parameters print without their (often internal) package.
              "arglist" (jarray (mapcar #'princ-to-string elements))
              "current" (json-or-null (and index (lambda-list-current elements index keyword)))
              "syntax" (json-or-null syntax)
              "doc" (json-or-null (symbol-doc-summary symbol kind)))))))

(defun special-operator-syntax (symbol)
  "The \"Syntax:\" line of SYMBOL's HyperSpec entry, e.g. for LET."
  (let ((text (ignore-errors (lookup-cl-spec-text (symbol-name symbol) :part "syntax"))))
    (when text
      (let ((line (find-if (lambda (line) (search (string-downcase (symbol-name symbol)) (string-downcase line)))
                           (rest (uiop:split-string text :separator '(#\Newline))))))
        (and line (string-trim " " line))))))

;;; --- describe, the HyperSpec, apropos ---

(defun lisp-repl-describe (name package)
  (let ((symbol (lisp-token-symbol name package)))
    (if symbol
        (let ((text (with-output-to-string (s)
                      (let ((*print-case* :downcase) (*package* package))
                        (describe symbol s)))))
          (if (> (length text) 30000) (concatenate 'string (subseq text 0 30000) "…") text))
        (format nil "No symbol named ~a is accessible in ~a." name (package-display-name package)))))

;;; --- macroexpansion ---

(defun lisp-repl-macroexpand (text package &key all)
  "TEXT's first form macroexpanded once (or, with ALL, completely), printed
in PACKAGE."
  (let* ((*package* package)
         (form (read-from-string text))
         (expansion (if all
                        (let ((expand-all (find-symbol "MACROEXPAND-ALL" "SB-CLTL2")))
                          (if expand-all (funcall expand-all form) (macroexpand form)))
                        (macroexpand-1 form))))
    (let ((*print-case* :downcase) (*print-pretty* t) (*print-right-margin* 80) (*print-circle* t))
      (prin1-to-string expansion))))

;;; --- M-. definition sources ---

(defparameter *lisp-definition-types*
  '(:function :macro :generic-function :method :compiler-macro :setf-expander
    :variable :constant :symbol-macro :class :condition :structure :type :method-combination))

(defun lisp-source-form-start (text offset)
  "Where the form after OFFSET begins, past blank lines and comments (a
definition's recorded position is just after the form before it)."
  (let ((i (min offset (length text))) (n (length text)))
    (loop
      (cond ((>= i n) (return n))
            ((whitespace-char-p (char text i)) (incf i))
            ((char= (char text i) #\;) (setf i (or (position #\Newline text :start i) n)))
            ((and (char= (char text i) #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
             (setf i (+ 2 (or (search "|#" text :start2 i) n))))
            (t (return i))))))

(defun lisp-form-end (text start)
  "Where the form starting at START in TEXT ends (one past it)."
  (let ((n (length text)) (i start))
    (flet ((delimiter-p (c) (or (whitespace-char-p c) (member c '(#\( #\) #\" #\;)))))
      (loop while (and (< i n) (member (char text i) '(#\' #\` #\,))) do (incf i)
            finally (when (and (< i n) (char= (char text i) #\@)) (incf i)))
      (when (and (< (1+ i) n) (char= (char text i) #\#) (char= (char text (1+ i)) #\'))
        (incf i 2))
      (cond ((>= i n) n)
            ((char= (char text i) #\")
             (loop for j from (1+ i) below n
                   when (char= (char text j) #\\) do (incf j)
                   else when (char= (char text j) #\") return (1+ j)
                   finally (return n)))
            ((or (char= (char text i) #\()
                 (and (char= (char text i) #\#) (< (1+ i) n) (char= (char text (1+ i)) #\()))
             (let ((j (1+ (position #\( text :start i))))
               (loop (setf j (lisp-source-form-start text j))
                     (cond ((>= j n) (return n))
                           ((char= (char text j) #\)) (return (1+ j)))
                           (t (setf j (lisp-form-end text j)))))))
            ((and (char= (char text i) #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
             (let ((j (min n (+ i 3))))
               (loop while (and (< j n) (not (delimiter-p (char text j)))) do (incf j))
               j))
            (t (let ((j i))
                 (loop while (and (< j n) (not (delimiter-p (char text j))))
                       do (incf j (if (char= (char text j) #\\) 2 1)))
                 (max j (1+ i))))))))

(defun lisp-subform-start (text start index)
  "Where element INDEX (0-based) of the list starting at START begins, or NIL."
  (let ((i (1+ (or (position #\( text :start start) (return-from lisp-subform-start nil)))))
    (dotimes (k (1+ index))
      (setf i (lisp-source-form-start text i))
      (when (or (>= i (length text)) (char= (char text i) #\))) (return-from lisp-subform-start nil))
      (when (= k index) (return-from lisp-subform-start i))
      (setf i (lisp-form-end text i)))))

(defun lisp-definition-start (text start end name)
  "The start of a (def... NAME ...) form between START and END in TEXT, for
a definition recorded only as part of a bigger toplevel form."
  (loop for open = (position #\( text :start start :end end)
        while open
        do (let* ((operator-end (lisp-form-end text (1+ open)))
                  (operator (subseq text (1+ open) (min operator-end end)))
                  (name-start (lisp-source-form-start text operator-end)))
             (when (and (> (length operator) 3) (string-equal "def" operator :end2 3)
                        (< name-start end))
               (let ((defined (string-left-trim "'" (subseq text name-start (lisp-form-end text name-start)))))
                 (when (string-equal (subseq defined (1+ (or (position #\: defined :from-end t) -1))) name)
                   (return open)))))
           (setf start (1+ open))))

(defun lisp-source-form-text (text start &optional path)
  "The form at START in TEXT, descending along PATH (subform indexes, as in
SB-INTROSPECT's form paths) when the definition is inside another form."
  (let ((start (or (loop with position = start
                         for index in path
                         do (setf position (lisp-subform-start text position index))
                         while position
                         finally (return position))
                   start)))
    (subseq text start (min (length text) (lisp-form-end text start) (+ start 20000)))))

(defun lisp-repl-definitions (name package)
  "Where NAME's definitions are: a list of plists (:type :file :line :snippet)."
  (let ((symbol (lisp-token-symbol name package))
        (results nil) (seen nil))
    (when symbol
      (dolist (type *lisp-definition-types*)
        (dolist (source (introspect "FIND-DEFINITION-SOURCES-BY-NAME" symbol type))
          (let* ((pathname (introspect "DEFINITION-SOURCE-PATHNAME" source))
                 (offset (introspect "DEFINITION-SOURCE-CHARACTER-OFFSET" source))
                 (form-path (introspect "DEFINITION-SOURCE-FORM-PATH" source))
                 (key (list (and pathname (namestring pathname)) offset)))
            (when (and pathname (not (member key seen :test #'equal)) (< (length results) 12))
              (push key seen)
              (let* ((file (probe-file (translate-logical-pathname pathname)))
                     (octets (and file (ignore-errors (uiop:read-file-string file :external-format :latin-1))))
                     ;; SBCL records the position in bytes; count characters.
                     (text (and file (ignore-errors (read-text-file file))))
                     (start (and text offset octets
                                 (lisp-source-form-start
                                  text (length (babel:octets-to-string
                                                (map '(vector (unsigned-byte 8)) #'char-code
                                                     (subseq octets 0 (min offset (length octets))))
                                                :encoding :utf-8 :errorp nil))))))
                (push (list :type (string-downcase (symbol-name type))
                            :file (namestring (or file pathname))
                            :line (and start (1+ (count #\Newline text
                                                        :end (or (lisp-definition-start text start (lisp-form-end text start)
                                                                                        (symbol-name symbol))
                                                                 start))))
                            :snippet (and start
                                          (let ((inner (lisp-definition-start text start (lisp-form-end text start)
                                                                              (symbol-name symbol))))
                                            (if inner
                                                (lisp-source-form-text text inner)
                                                (lisp-source-form-text text start (rest form-path))))))
                      results)))))))
    (nreverse results)))

;;; --- the inspector ---

(defun lisp-short-print (object)
  (let ((*print-length* 12) (*print-level* 3) (*print-lines* 1))
    (lisp-repl-print object :limit 300 :pretty nil)))

(defun lisp-inspector-parts (object)
  "What the inspector lists for OBJECT: (LABEL . VALUE) pairs, where a VALUE
of (:text STRING) is shown as plain text rather than as an object."
  (flet ((text (string) (list :text string)))
    (typecase object
      (symbol
       (append (list (cons "name" (text (symbol-name object)))
                     (cons "package" (or (symbol-package object) (text "uninterned"))))
               (when (boundp object) (list (cons "value" (symbol-value object))))
               (when (fboundp object) (list (cons "function" (if (macro-function object)
                                                                (text "a macro")
                                                                (if (special-operator-p object)
                                                                    (text "a special operator")
                                                                    (fdefinition object))))))
               (when (find-class object nil) (list (cons "class" (find-class object))))
               (when (symbol-plist object) (list (cons "plist" (symbol-plist object))))))
      (package
       (list (cons "name" (text (package-name object)))
             (cons "nicknames" (package-nicknames object))
             (cons "uses" (package-use-list object))
             (cons "used by" (package-used-by-list object))
             (cons "external symbols"
                   (let (symbols) (do-external-symbols (s object) (push s symbols))
                     (sort symbols #'string<)))))
      (hash-table
       (append (list (cons "count" (hash-table-count object))
                     (cons "test" (hash-table-test object)))
               (let (entries)
                 (block collect
                   (maphash (lambda (key value)
                              (when (>= (length entries) 500) (return-from collect))
                              (push (cons (lisp-short-print key) value) entries))
                            object))
                 (nreverse entries))))
      (string (list (cons "length" (length object)) (cons "text" (text object))))
      (cons
       (let ((length (ignore-errors (list-length object))))
         (if length
             (loop for element in object for i from 0 below 500
                   collect (cons (princ-to-string i) element))
             (list (cons "car" (car object)) (cons "cdr" (cdr object))))))
      (array
       (append (list (cons "dimensions" (array-dimensions object))
                     (cons "element type" (array-element-type object)))
               (when (array-has-fill-pointer-p object) (list (cons "fill pointer" (fill-pointer object))))
               (loop for i from 0 below (min 500 (array-total-size object))
                     collect (cons (princ-to-string i) (row-major-aref object i)))))
      (character (list (cons "code" (char-code object)) (cons "name" (text (or (char-name object) "")))))
      (integer (list (cons "decimal" (text (format nil "~:d" object)))
                     (cons "hex" (text (format nil "#x~x" object)))
                     (cons "binary" (text (format nil "#b~b" object)))
                     (cons "integer length" (integer-length object))))
      (ratio (list (cons "numerator" (numerator object)) (cons "denominator" (denominator object))
                   (cons "as a float" (float object 1d0))))
      (complex (list (cons "real part" (realpart object)) (cons "imaginary part" (imagpart object))))
      (number (list (cons "type" (type-of object))))
      (pathname (list (cons "namestring" (text (namestring object)))
                      (cons "directory" (pathname-directory object))
                      (cons "name" (pathname-name object)) (cons "type" (pathname-type object))))
      (generic-function
       (list (cons "name" (sb-mop:generic-function-name object))
             (cons "lambda list" (sb-mop:generic-function-lambda-list object))
             (cons "documentation" (text (or (documentation object t) "")))
             (cons "methods" (sb-mop:generic-function-methods object))))
      (function
       (list (cons "name" (nth-value 2 (function-lambda-expression object)))
             (cons "lambda list" (text (let ((*print-case* :downcase))
                                         (prin1-to-string (introspect "FUNCTION-LAMBDA-LIST" object)))))
             (cons "documentation" (text (or (documentation object t) "")))))
      (class
       (list (cons "name" (class-name object))
             (cons "direct superclasses" (sb-mop:class-direct-superclasses object))
             (cons "precedence list" (ignore-errors (sb-mop:class-precedence-list object)))
             (cons "slots" (mapcar #'sb-mop:slot-definition-name
                                   (ignore-errors (sb-mop:class-slots object))))
             (cons "direct subclasses" (sb-mop:class-direct-subclasses object))))
      (t
       (let ((slots (ignore-errors (sb-mop:class-slots (class-of object)))))
         (if slots
             (cons (cons "class" (class-of object))
                   (append (when (typep object 'condition)
                             (list (cons "report" (text (or (ignore-errors (princ-to-string object)) "")))))
                           (mapcar (lambda (slot)
                                     (let ((name (sb-mop:slot-definition-name slot)))
                                       (cons (string-downcase (symbol-name name))
                                             (handler-case
                                                 (if (slot-boundp object name)
                                                     (slot-value object name)
                                                     (text "unbound"))
                                               (error () (text "unreadable"))))))
                                   slots)))
             (list (cons "description" (text (with-output-to-string (s) (describe object s)))))))))))

(defun lisp-repl-inspect (id &optional (repl *lisp-repl*))
  "The inspector's view of presented object ID, as a JOBJ."
  (let* ((object (lisp-repl-object id repl))
         (parts (lisp-inspector-parts object)))
    (jobj "id" id
          "title" (lisp-short-print object)
          "type" (lisp-repl-print (type-of object) :limit 200 :pretty nil)
          "parts" (jarray
                   (mapcar (lambda (part)
                             (destructuring-bind (label . value) part
                               (if (and (consp value) (eq (first value) :text))
                                   (jobj "label" label "text" (second value) "id" :null)
                                   (jobj "label" label "text" (lisp-short-print value)
                                         "id" (lisp-repl-present value repl)))))
                           parts)))))
