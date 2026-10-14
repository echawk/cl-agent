;;;; quality.lisp -- one review pipeline for every model-authored Lisp path.

(in-package :cl-agent)

(defparameter *lisp-review-config-path*
  (asdf:system-relative-pathname "cl-agent" ".mallet.lisp"))

(defvar *lisp-review-config* nil)

(defun lisp-review-config ()
  "Return the project's strict Mallet configuration, loading it lazily."
  (or *lisp-review-config*
      (setf *lisp-review-config* (mallet:load-config *lisp-review-config-path*))))

(defvar *temporary-name-random-state* (make-random-state t))

(defun temporary-lisp-pathname (&optional (type "lisp"))
  "Return a fresh pathname in UIOP:TEMPORARY-DIRECTORY."
  (merge-pathnames
   ;; GENSYM's counter starts alike in every process: two agents (or two
   ;; live sessions) would share files.  The process and a random part keep
   ;; them apart.
   (make-pathname :name (format nil "cl-agent-review-~d-~36r-~(~a~)"
                                (sb-unix:unix-getpid) (random (expt 36 8) *temporary-name-random-state*)
                                (symbol-name (gensym "")))
                  :type type)
   (uiop:temporary-directory)))

(defun call-with-temporary-lisp-source (source function &key name)
  "Write SOURCE to a temporary .lisp file and call FUNCTION with its path.
With NAME (\"repl.lisp\"), the file has that name, in a fresh temporary
directory, so findings about it read as findings about NAME."
  (let* ((directory (and name (merge-pathnames (format nil "~a/" (pathname-name (temporary-lisp-pathname)))
                                               (uiop:temporary-directory))))
         (path (if directory (merge-pathnames (file-namestring name) directory) (temporary-lisp-pathname))))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (with-open-file (out path :direction :output :if-exists :error
                                :if-does-not-exist :create :external-format :utf-8)
             (write-string source out))
           (funcall function path))
      (when (probe-file path)
        (delete-file path))
      (when directory
        (ignore-errors (uiop:delete-empty-directory directory))))))

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

;;; Compiling is not inert in SBCL: COMPILE-FILE defines the macros, compiler
;;; macros, structures and packages a file names, at compile time, in this
;;; very image -- so reviewing an edited copy of the agent's own source would
;;; change the macros it runs on.  The compile check therefore snapshots
;;; those and puts back what it changed (constants it cannot), and reviews
;;; run one at a time.

(defvar *review-compile-lock* (bordeaux-threads:make-recursive-lock "cl-agent review compile"))

(defun image-definitions-snapshot ()
  "The packages, and every symbol's macro, compiler macro and class."
  (let ((symbols (make-hash-table :test 'eq)))
    (do-all-symbols (symbol)
      (let ((macro (macro-function symbol))
            (compiler-macro (compiler-macro-function symbol))
            (class (find-class symbol nil)))
        (when (or macro compiler-macro class)
          (setf (gethash symbol symbols) (list macro compiler-macro class)))))
    (list :packages (list-all-packages) :symbols symbols)))

(defun restore-image-definitions (snapshot source)
  "Undo what compiling SOURCE did to the definitions SNAPSHOT recorded: put
back changed macros and compiler macros, remove new ones and new classes,
and delete new packages.  Only symbols SOURCE names are touched, so another
thread's definitions made meanwhile are left alone."
  (let ((symbols (getf snapshot :symbols))
        (text (string-upcase source)))
    (sb-ext:without-package-locks
      (do-all-symbols (symbol)
        (destructuring-bind (&optional old-macro old-compiler-macro old-class) (gethash symbol symbols)
          (let ((macro (macro-function symbol))
                (compiler-macro (compiler-macro-function symbol))
                (class (find-class symbol nil)))
            (when (and (or (not (eq macro old-macro)) (not (eq compiler-macro old-compiler-macro))
                           (and class (not old-class)))
                       (search (symbol-name symbol) text))
              (handler-case
                  (progn
                    (unless (eq macro old-macro)
                      (if old-macro (setf (macro-function symbol) old-macro) (fmakunbound symbol)))
                    (unless (eq compiler-macro old-compiler-macro)
                      (setf (compiler-macro-function symbol) old-compiler-macro))
                    (when (and class (not old-class))
                      (setf (find-class symbol) nil)))
                (error () nil)))))))
    (dolist (package (set-difference (list-all-packages) (getf snapshot :packages)))
      (handler-case (delete-package package) (error () nil)))))

(defun missing-package-names (diagnostics)
  "Names of packages DIAGNOSTICS say do not exist."
  (let ((names nil))
    (dolist (text diagnostics (nreverse names))
      (dolist (pattern '("Package " "The name \""))
        (loop with start = 0
              for at = (search pattern text :start2 start)
              while at
              do (let* ((from (+ at (length pattern)))
                        (to (position-if (lambda (c) (member c '(#\Space #\" #\Newline))) text :start from)))
                   (when (and to (or (search " does not exist" text :start2 to :end2 (min (length text) (+ to 16)))
                                     (search "\" does not designate any package" text :start2 to
                                                                                      :end2 (min (length text) (+ to 34)))))
                     (pushnew (subseq text from to) names :test #'string=))
                   (setf start from)))))))

(defun compile-lisp-source (source &key package name)
  "Compile SOURCE in a temporary file (named NAME, if given), in PACKAGE
(a designator) when given, else the current package.

Returns (values diagnostics warnings-p failure-p missing-packages).  No FASL
is retained, and the definitions compiling installs in this image are undone
(see RESTORE-IMAGE-DEFINITIONS)."
  (bordeaux-threads:with-recursive-lock-held (*review-compile-lock*)
    (let ((snapshot (image-definitions-snapshot)))
      (unwind-protect
           (multiple-value-bind (diagnostics warnings-p failure-p)
               (let ((*package* (if package
                                    (or (find-package (string-upcase (string package)))
                                        (error "There is no package ~a in this image." package))
                                    *package*)))
                 (%compile-lisp-source source name))
             (let ((missing (and failure-p (missing-package-names diagnostics))))
               (values diagnostics warnings-p failure-p missing)))
        (restore-image-definitions snapshot source)))))

(defun %compile-lisp-source (source name)
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
                        ;; Its own compilation unit: undefined functions are
                        ;; reported when a unit ends, and an enclosing one
                        ;; (a load in progress) would keep them from this review.
                        ;; The source is the model's: no read-time evaluation,
                        ;; no exiting, and a limit on runaway macros (guard.lisp).
                        (contained-agent-code (:where "Compiling this source")
                          (let ((*read-eval* nil))
                            (sb-ext:with-timeout 120
                              (with-compilation-unit (:override t)
                                (compile-file source-path :output-file output-path
                                                          :verbose nil :print nil)))))
                      (declare (ignore result))
                      (let ((captured (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                   (get-output-stream-string compiler-output))))
                        (when (plusp (length captured))
                          (pushnew captured diagnostics :test #'string=)))
                      (values (nreverse diagnostics) warnings-p failure-p))
                  (serious-condition (condition)
                    (pushnew (condition-summary condition) diagnostics :test #'string=)
                    (values (nreverse diagnostics) nil t)))))
         (when (probe-file output-path)
           (delete-file output-path)))))
   :name name))

(defun violation-weight (violation)
  "Weight a Mallet VIOLATION for the aggregate smell score."
  (case (mallet:violation-severity violation)
    (:error 100)
    (:warning 10)
    (otherwise 1)))

(defun review-lisp-input (source lint-path &key (compile-p t) package)
  "Review SOURCE, reporting Mallet findings against LINT-PATH.

Compilation deliberately still uses a disposable copy of SOURCE, so checking
an ordinary project file never leaves a FASL beside that file.  Code that
needs a package this image lacks (another project's file whose system is not
loaded) cannot be compiled here: the review then says so, under
:COMPILE-SKIPPED, rather than calling it a failed compilation."
  (let* ((violations (mallet:lint-file lint-path :config (lisp-review-config)))
         (missing (missing-type-claims source lint-path)))
    (multiple-value-bind (diagnostics warnings-p failure-p missing-packages)
        (if compile-p
            (compile-lisp-source source :package package :name (file-namestring lint-path))
            (values nil nil nil nil))
      (let ((skipped (and missing-packages
                          (format nil "it uses package~p ~{~a~^, ~}, not loaded in this image (load ~
                                       its system with load-asdf-system to compile-check it here)"
                                  (length missing-packages) missing-packages))))
        (list :score (+ (reduce #'+ violations :key #'violation-weight :initial-value 0)
                        (* 25 (length missing))
                        (if skipped 0 (* 10 (length diagnostics)))
                        (if (and failure-p (not skipped)) 1000 0))
              :violations violations
              :missing-type-claims missing
              :compiler-diagnostics (if skipped nil diagnostics)
              :compiler-warnings-p (and (not skipped) warnings-p)
              :compile-failure-p (and failure-p (not skipped))
              :compile-skipped (or skipped (and (not compile-p) "not requested")))))))

(defun review-lisp-source (source &key (compile-p t) package name)
  "Review SOURCE with Mallet, type-claim checks, and optionally SBCL
(compiling in PACKAGE when SOURCE has no IN-PACKAGE of its own).  NAME is the
file name findings are reported against.

The returned plist contains :SCORE, :VIOLATIONS, :MISSING-TYPE-CLAIMS,
:COMPILER-DIAGNOSTICS, :COMPILER-WARNINGS-P, :COMPILE-FAILURE-P and
:COMPILE-SKIPPED.  A score is guidance, not a gate; only :COMPILE-FAILURE-P
should prevent code from running."
  (check-type source string)
  (call-with-temporary-lisp-source
   source
   (lambda (path)
     (review-lisp-input source path :compile-p compile-p :package package))
   :name name))

(defun review-lisp-file (path &key (compile-p t) package)
  "Review the Common Lisp source file at PATH without modifying it.

PATH is a file on disk, or a source the lisp-source tool names: SYSTEM/PATH
(cl-agent/src/repl.lisp), or a file only the built image still holds
(source-archive.lisp).  Mallet receives the actual file when there is one,
preserving useful file/line locations in its findings, while compilation runs
against a disposable copy to avoid artifacts in the project tree."
  (unless (and (stringp path) (plusp (length (string-trim " " path))))
    (error "Lisp review path must be a non-empty string"))
  (let ((resolved (probe-file path)))
    (cond ((and resolved (uiop:directory-pathname-p resolved))
           (error "Lisp review path names a directory, not a file: ~a" path))
          (resolved
           (review-lisp-input (read-text-file resolved) resolved :compile-p compile-p :package package))
          (t
           (let ((found (find-archived-source path)))
             (unless found
               (error "Lisp review file does not exist: ~a (give a file path, SYSTEM/PATH as the ~
                       lisp-source tool lists it, or the source text itself)" path))
             (destructuring-bind (key . entry) found
               (review-lisp-source (or (archived-source-text key entry)
                                       (error "Cannot read the source of ~a." path))
                                   :compile-p compile-p :package package
                                   :name (file-namestring (archived-source-path entry)))))))))

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
      ((getf review :compile-skipped)
       (format out "Compilation: not checked: ~a.~%" (getf review :compile-skipped)))
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
