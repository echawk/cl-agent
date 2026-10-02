;;;; apropos.lisp -- search every loaded Lisp package for a function,
;;;; macro, variable, or class by name substring: the practical
;;;; equivalent of a Hoogle-style search when there's no type-
;;;; signature index to search instead. This image already has
;;;; alexandria, serapeum, iterate, and trivia loaded (transitively,
;;;; via other dependencies -- see cl-agent.asd) alongside plain
;;;; Common Lisp and cl-agent's own code, so a substring search over
;;;; every loaded package reaches a lot of real, already-available
;;;; utility code, not just the ANSI standard (LOOKUP-CL-SPEC-TEXT,
;;;; clspec.lisp, covers that separately). Exists so the model has a
;;;; real way to check "does something like this already exist"
;;;; before reaching for WRITE-EXTENSION -- see the LISP-APROPOS tool,
;;;; tools/apropos-tool.lisp.

(in-package :cl-agent)

#+sbcl (eval-when (:load-toplevel :execute) (ignore-errors (require :sb-introspect)))

(defparameter *apropos-result-limit* 40
  "Max matches LISP-APROPOS-TEXT renders in full before truncating --
a substring search over every loaded package can match hundreds of
symbols; a long, truncated list is still useful context, an unbounded
one just burns the model's context window for nothing.")

(defun symbol-kind (symbol)
  "One of :special-operator :macro :generic-function :function :class
:variable, or NIL if SYMBOL names none of those (e.g. a plain data
symbol, or only a slot/keyword-argument name)."
  (cond
    ((special-operator-p symbol) :special-operator)
    ((macro-function symbol) :macro)
    ((and (fboundp symbol) (typep (symbol-function symbol) 'generic-function)) :generic-function)
    ((fboundp symbol) :function)
    ((find-class symbol nil) :class)
    ((boundp symbol) :variable)
    (t nil)))

(defun symbol-lambda-list (symbol kind)
  "SYMBOL's lambda list if KIND is callable and SB-INTROSPECT can
determine it, else NIL -- never signals (a built-in or compiled-away
function occasionally has no recoverable lambda list). Looked up by
name via FIND-SYMBOL, not written as SB-INTROSPECT:FUNCTION-LAMBDA-
LIST directly, so this file's reader never needs that package to
exist (same reasoning as REGISTRY.LISP's FORGET-ENV, for SB-POSIX)."
  (and (member kind '(:function :macro :generic-function))
       #+sbcl
       (let ((fn (find-symbol "FUNCTION-LAMBDA-LIST" "SB-INTROSPECT")))
         (and fn (ignore-errors (funcall fn symbol))))
       #-sbcl nil))

(defun symbol-doc-summary (symbol kind)
  "First line of SYMBOL's docstring for KIND, or NIL."
  (let ((doc (ignore-errors
               (documentation symbol (case kind
                                        ((:function :macro :special-operator :generic-function) 'function)
                                        (:variable 'variable)
                                        ((:class :type) 'type))))))
    (and doc (plusp (length doc))
         (let ((newline (position #\newline doc)))
           (string-trim " " (if newline (subseq doc 0 newline) doc))))))

(defun lisp-apropos-matches (query &key package)
  "(SYMBOL KIND) pairs across every loaded package (or just PACKAGE, a
string designator, if given) whose name contains QUERY (case-
insensitive, via APROPOS-LIST) and that SYMBOL-KIND recognizes,
deduplicated (APROPOS-LIST can list one symbol once per package it's
accessible in -- e.g. an inherited COMMON-LISP symbol) and sorted by
name. Signals a plain error, not a condition the model has no way to
act on, if PACKAGE doesn't name a loaded package."
  (let ((pkg (and package
                  (or (find-package (string-upcase package))
                      (error "no package named ~s is currently loaded" package)))))
    (sort (remove-duplicates
           (loop for sym in (apropos-list query pkg)
                 for kind = (symbol-kind sym)
                 when kind collect (list sym kind))
           :key #'first :test #'eq)
          #'string< :key (lambda (entry) (symbol-name (first entry))))))

(defun split-on-whitespace (string)
  (loop with start = 0
        for space = (position #\space string :start start)
        collect (subseq string start space)
        while space do (setf start (1+ space))))

(defun lisp-apropos-text (query &key package)
  "Human/model-readable rendering of LISP-APROPOS-MATCHES: one line per
match, \"PACKAGE:NAME kind (lambda-list) -- doc summary\", truncated to
*APROPOS-RESULT-LIMIT* with a note of how many more were omitted. A
multi-word QUERY (e.g. \"reverse words\") that matches nothing as one
phrase is retried one word at a time and the merged results of those
are returned instead, noted as such -- a name search has no notion of
word order or \"contains all of these\", so a query built like a search
engine query would otherwise come back empty for no good reason."
  (handler-case
      (let ((matches (lisp-apropos-matches query :package package))
            (per-word-note ""))
        (when (and (null matches) (find #\space query))
          (setf matches (sort (remove-duplicates
                                (loop for word in (split-on-whitespace query)
                                      unless (zerop (length word))
                                        append (lisp-apropos-matches word :package package))
                                :key #'first :test #'eq)
                               #'string< :key (lambda (entry) (symbol-name (first entry))))
                per-word-note (format nil "No match for ~s as one phrase -- showing matches for its individual words instead.~%" query)))
        (let* ((total (length matches))
               (shown (subseq matches 0 (min total *apropos-result-limit*))))
          (if (null matches)
              (format nil "No loaded function, macro, variable, or class name contains ~s (tried both as one phrase and as individual words).~@[ (searched only package ~a.)~]"
                      query package)
              (format nil "~a~{~a~^~%~}~@[~%...and ~d more not shown -- narrow QUERY or pass PACKAGE to see them.~]"
                      per-word-note
                      (mapcar (lambda (entry)
                                (destructuring-bind (sym kind) entry
                                  (format nil "~a:~a ~(~a~)~@[ ~a~]~@[ -- ~a~]"
                                          (package-name (symbol-package sym)) (symbol-name sym) kind
                                          (symbol-lambda-list sym kind) (symbol-doc-summary sym kind))))
                              shown)
                      (and (> total *apropos-result-limit*) (- total *apropos-result-limit*))))))
    (error (c) (format nil "lisp-apropos error: ~a" c))))
