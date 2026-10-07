;;;; quality.lisp -- one review pipeline for every model-authored Lisp path.

(in-package :cl-agent)

(defparameter *lisp-review-config-path*
  (asdf:system-relative-pathname "cl-agent" ".mallet.lisp"))

(defvar *lisp-review-config* nil)

(defun lisp-review-config ()
  "Return the project's strict Mallet configuration, loading it lazily."
  (or *lisp-review-config*
      (setf *lisp-review-config* (mallet:load-config *lisp-review-config-path*))))

(defun temporary-lisp-pathname (&optional (type "lisp"))
  "Return a fresh pathname in UIOP:TEMPORARY-DIRECTORY."
  (merge-pathnames
   (make-pathname :name (string-downcase (symbol-name (gensym "cl-agent-review-")))
                  :type type)
   (uiop:temporary-directory)))

(defun call-with-temporary-lisp-source (source function)
  "Write SOURCE to a temporary .lisp file and call FUNCTION with its path."
  (let ((path (temporary-lisp-pathname)))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :error
                                :if-does-not-exist :create)
             (write-string source out))
           (funcall function path))
      (when (probe-file path)
        (delete-file path)))))

(defun definition-name-key (name)
  "Normalize an ordinary or (SETF ...) function NAME for comparison."
  (labels ((part (value)
             (etypecase value
               (symbol (symbol-name value))
               (string (let ((colon (position #\: value :from-end t)))
                         (if colon (subseq value (1+ colon)) value)))
               (cons (format nil "(~{~a~^ ~})" (mapcar #'part value))))))
    (string-upcase (part name))))

(defun parsed-operator-name (value)
  "Return Mallet parser VALUE's unqualified, uppercase operator name."
  (when (or (symbolp value) (stringp value))
    (definition-name-key value)))

(defun source-type-claims (source path)
  "Return (values defined-functions typed-functions) found in SOURCE.

DEFUN*/DEFMETHOD*/DEFGENERIC* count as typed definitions.  An FTYPE DECLAIM
counts for each function it names.  The comparison is deliberately based on
printed names so this analysis also works for source defining a new package."
  (multiple-value-bind (parsed parse-errors) (mallet:parse-forms source path)
    (declare (ignore parse-errors))
    (let ((defined nil)
          (typed nil))
      (labels ((note-defined (name)
                 (when name
                   (pushnew (definition-name-key name) defined :test #'string=)))
               (note-typed (name)
                 (when name
                   (pushnew (definition-name-key name) typed :test #'string=)))
               (walk (expression)
                 (when (consp expression)
                   (let ((operator (parsed-operator-name (first expression))))
                     (cond
                       ((member operator '("DEFUN" "DEFMETHOD" "DEFGENERIC") :test #'string=)
                        (note-defined (second expression)))
                       ((member operator '("DEFUN*" "DEFMETHOD*" "DEFGENERIC*") :test #'string=)
                        (let ((name (second expression)))
                          (when (consp name) (setf name (first name)))
                          (note-defined name)
                          (note-typed name)))
                       ((string= operator "DECLAIM")
                        (dolist (declaration (rest expression))
                          (when (and (consp declaration)
                                     (string= (parsed-operator-name (first declaration)) "FTYPE"))
                            (dolist (name (cddr declaration))
                              (note-typed name)))))
                       ((member operator '("PROGN" "EVAL-WHEN") :test #'string=)
                        (dolist (child (rest expression)) (walk child))))))))
        (dolist (form parsed) (walk (mallet:form-expr form))))
      (values (nreverse defined) (nreverse typed)))))

(defun missing-type-claims (source path)
  "Return names of functions in SOURCE lacking DEFSTAR or FTYPE claims."
  (multiple-value-bind (defined typed) (source-type-claims source path)
    (set-difference defined typed :test #'string=)))

(defun condition-summary (condition)
  "Return one compact, stable line for a compiler CONDITION."
  (with-output-to-string (out)
    (let ((*print-pretty* nil))
      (princ condition out))))

(defun compile-lisp-source (source)
  "Compile SOURCE in a temporary file.

Returns (values diagnostics warnings-p failure-p).  No FASL is retained."
  (call-with-temporary-lisp-source
   source
   (lambda (source-path)
     (let ((output-path (compile-file-pathname source-path))
           (diagnostics nil)
           (compiler-output (make-string-output-stream)))
       (unwind-protect
            (handler-bind
                ((warning
                   (lambda (condition)
                     (pushnew (condition-summary condition) diagnostics :test #'string=)
                     (let ((restart (find-restart 'muffle-warning condition)))
                       (when restart (invoke-restart restart))))))
              (let ((*error-output* compiler-output)
                    (*standard-output* compiler-output))
                (handler-case
                    (multiple-value-bind (result warnings-p failure-p)
                        (compile-file source-path :output-file output-path
                                                  :verbose nil :print nil)
                      (declare (ignore result))
                      (let ((captured (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                   (get-output-stream-string compiler-output))))
                        (when (plusp (length captured))
                          (pushnew captured diagnostics :test #'string=)))
                      (values (nreverse diagnostics) warnings-p failure-p))
                  (error (condition)
                    (pushnew (condition-summary condition) diagnostics :test #'string=)
                    (values (nreverse diagnostics) nil t)))))
         (when (probe-file output-path)
           (delete-file output-path)))))))

(defun violation-weight (violation)
  "Weight a Mallet VIOLATION for the aggregate smell score."
  (case (mallet:violation-severity violation)
    (:error 100)
    (:warning 10)
    (otherwise 1)))

(defun review-lisp-input (source lint-path &key (compile-p t))
  "Review SOURCE, reporting Mallet findings against LINT-PATH.

Compilation deliberately still uses a disposable copy of SOURCE, so checking
an ordinary project file never leaves a FASL beside that file."
  (let* ((violations (mallet:lint-file lint-path :config (lisp-review-config)))
         (missing (missing-type-claims source lint-path)))
    (multiple-value-bind (diagnostics warnings-p failure-p)
        (if compile-p (compile-lisp-source source) (values nil nil nil))
      (list :score (+ (reduce #'+ violations :key #'violation-weight :initial-value 0)
                      (* 25 (length missing))
                      (* 10 (length diagnostics))
                      (if failure-p 1000 0))
            :violations violations
            :missing-type-claims missing
            :compiler-diagnostics diagnostics
            :compiler-warnings-p warnings-p
            :compile-failure-p failure-p))))

(defun review-lisp-source (source &key (compile-p t))
  "Review SOURCE with Mallet, type-claim checks, and optionally SBCL.

The returned plist contains :SCORE, :VIOLATIONS, :MISSING-TYPE-CLAIMS,
:COMPILER-DIAGNOSTICS, :COMPILER-WARNINGS-P and :COMPILE-FAILURE-P.  A score is
guidance, not a gate; only :COMPILE-FAILURE-P should prevent code from running."
  (check-type source string)
  (call-with-temporary-lisp-source
   source
   (lambda (path)
     (review-lisp-input source path :compile-p compile-p))))

(defun review-lisp-file (path &key (compile-p t))
  "Review the Common Lisp source file at PATH without modifying it.

Mallet receives the actual file, preserving useful file/line locations in its
findings, while compilation runs against a disposable copy to avoid artifacts
in the project tree."
  (unless (and (stringp path) (plusp (length (string-trim " " path))))
    (error "Lisp review path must be a non-empty string"))
  (let ((resolved (probe-file path)))
    (unless resolved (error "Lisp review file does not exist: ~a" path))
    (when (uiop:directory-pathname-p resolved)
      (error "Lisp review path names a directory, not a file: ~a" path))
    (review-lisp-input (uiop:read-file-string resolved) resolved :compile-p compile-p)))

(defun format-lisp-review (review)
  "Render REVIEW-LISP-SOURCE's result for a model or human."
  (with-output-to-string (out)
    (format out "Lisp quality score: ~d (lower is better).~%" (getf review :score))
    (dolist (violation (getf review :violations))
      (format out "Mallet ~a:~d:~d [~(~a~)/~(~a~)] ~a~%"
              (file-namestring (mallet:violation-file violation))
              (mallet:violation-line violation)
              (mallet:violation-column violation)
              (mallet:violation-severity violation)
              (mallet:violation-rule violation)
              (mallet:violation-message violation)))
    (when (getf review :missing-type-claims)
      (format out "Missing type claim (use DEFUN* or DECLAIM FTYPE): ~{~a~^, ~}~%"
              (getf review :missing-type-claims)))
    (dolist (diagnostic (getf review :compiler-diagnostics))
      (format out "Compiler: ~a~%" diagnostic))
    (cond
      ((getf review :compile-failure-p) (format out "Compilation: FAILED.~%"))
      ((getf review :compiler-warnings-p) (format out "Compilation: succeeded with warnings.~%"))
      (t (format out "Compilation: succeeded.~%")))))

(defun common-lisp-fence-language-p (language)
  "True when a Markdown fence LANGUAGE denotes Common Lisp."
  (member (string-downcase (string-trim '(#\Space #\Tab) language))
          '("lisp" "common-lisp" "commonlisp" "cl") :test #'string=))

(defun trim-trailing-whitespace (source)
  "Remove only spaces and tabs at the end of each SOURCE line.
This is deliberately not a pretty-printer: it preserves every token, newline,
and form while eliminating a common, low-value LLM lint finding."
  (with-output-to-string (out)
    (loop with start = 0
          for newline = (position #\Newline source :start start)
          for end = (or newline (length source))
          do (write-string (string-right-trim '(#\Space #\Tab #\Return)
                                               (subseq source start end)) out)
             (when newline (write-char #\Newline out))
             (setf start (if newline (1+ newline) (length source)))
          until (null newline))))

(defun pretty-print-common-lisp-source (source)
  "Pretty-print parseable SOURCE, otherwise return it unchanged.

Mallet is the parse gate: malformed parentheses or reader syntax are retained
verbatim for the model to repair rather than being obscured by a formatter."
  (call-with-temporary-lisp-source
   source
   (lambda (path)
     (multiple-value-bind (forms parse-errors) (mallet:parse-forms source path)
       (declare (ignore forms))
       (if parse-errors
           source
           (handler-case
               (with-input-from-string (in source)
                 (with-output-to-string (out)
                   (let ((*read-eval* nil)
                         (*package* (find-package :cl-user))
                         (*print-pretty* t)
                         (*print-right-margin* 88))
                     (loop for form = (read in nil :eof)
                           until (eq form :eof)
                           do (pprint form out)))))
             ;; A valid Mallet parse can still use implementation-specific
             ;; reader syntax. Preserve such source rather than damaging it.
             (error () source)))))))

(defun normalize-assistant-common-lisp (content)
  "Trim trailing whitespace in fenced Common Lisp, preserving all other text.
Parseable blocks are then pretty-printed. The normalized text is both shown to
the user and reviewed by Mallet."
  (with-output-to-string (out)
    (loop with cursor = 0
          do (let ((opening (search "```" content :start2 cursor)))
               (unless opening
                 (write-string content out :start cursor)
                 (return))
               (let* ((opening-end (position #\Newline content :start (+ opening 3)))
                      (closing (and opening-end
                                    (search (format nil "~%```") content :start2 (1+ opening-end)))))
                 (unless (and opening-end closing)
                   (write-string content out :start cursor)
                   (return))
                 (let ((language (subseq content (+ opening 3) opening-end)))
                   (if (common-lisp-fence-language-p language)
                       (progn
                         (write-string content out :start cursor :end (1+ opening-end))
                         (let ((formatted
                                 (string-left-trim '(#\Newline #\Return)
                                                   (pretty-print-common-lisp-source
                                                    (trim-trailing-whitespace
                                                     (subseq content (1+ opening-end) closing))))))
                           (write-string formatted out)
                           ;; PPRINT may start a fresh line but does not promise
                           ;; to end one; keep the closing fence on its own line.
                           (unless (and (plusp (length formatted))
                                        (char= (char formatted (1- (length formatted))) #\Newline))
                             (terpri out)))
                         (write-string "```" out)
                         (setf cursor (+ closing 4)))
                       (progn
                         (write-string content out :start cursor :end (+ closing 4))
                         (setf cursor (+ closing 4))))))))))

(defun extract-common-lisp-code-blocks (text)
  "Return Common Lisp bodies from fenced Markdown in TEXT."
  (let ((blocks nil)
        (collecting nil)
        (body nil))
    (with-input-from-string (in text)
      (loop for line = (read-line in nil nil)
            while line
            do (cond
                 ((and (not collecting)
                       (<= 3 (length line))
                       (string= "```" line :end2 3)
                       (common-lisp-fence-language-p (subseq line 3)))
                  (setf collecting t body nil))
                 ((and collecting (string= "```" (string-trim '(#\Space #\Tab) line)))
                  (push (format nil "~{~a~%~}" (nreverse body)) blocks)
                  (setf collecting nil body nil))
                 (collecting (push line body)))))
    (nreverse blocks)))

(defun review-assistant-common-lisp (content)
  "Review every fenced Common Lisp block in assistant CONTENT."
  (loop for source in (extract-common-lisp-code-blocks
                       (normalize-assistant-common-lisp (or content "")))
        collect (review-lisp-source source)))

(defun lisp-review-needs-revision-p (review)
  "True only when a user-facing Lisp block fails to compile.

Mallet findings and absent type claims remain useful review information, but
they are not a reason to force a revision of ordinary code written for users.
The eval-lisp and write-extension tools keep their own stricter gate because
that code executes inside the agent itself."
  (getf review :compile-failure-p))

(defun format-assistant-lisp-reviews (reviews)
  "Render numbered REVIEWS as feedback for the generating model."
  (with-output-to-string (out)
    (format out "Automatic review found a Common Lisp compilation failure. Revise the code to compile while preserving the requested behavior. Mallet findings and type claims are advisory for user-facing code.~%")
    (loop for review in reviews
          for index from 1
          do (format out "~%Code block ~d:~%~a" index (format-lisp-review review)))))
