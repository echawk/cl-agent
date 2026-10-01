;;;; clspec.lisp -- look up a symbol (function, macro, special operator,
;;;; variable, type, ...) in the ANSI Common Lisp standard itself.
;;;;
;;;; The data comes from https://codeberg.org/dlowe/metaspectre, which
;;;; parses the draft ANSI standard's TeX sources into "sdoc": plain
;;;; s-expressions, documented in that project's doc/output-spec.md.
;;;; We do NOT depend on metaspectre (or its own dependencies --
;;;; alexandria, cl-ppcre, and an unpublished templating library) at
;;;; cl-agent's runtime. Instead, `scripts/build-clspec-data.sh` runs
;;;; metaspectre once to produce data/cl-spec.sdoc, which IS committed
;;;; to this repo; this file's only job at runtime is to READ that
;;;; file (plain data, no code) and render the entries it contains as
;;;; plain text. See that script's header comment for the full
;;;; rationale and how to regenerate the file.
;;;;
;;;; The exposed capability is the LOOKUP-CL-SPEC-TEXT function and the
;;;; lookup-cl-spec TOOL built on top of it, in
;;;; src/tools/clspec-tool.lisp.

(in-package :cl-agent)

(defparameter *clspec-data-pathname-override* nil
  "Set this (or the CL_AGENT_SPEC_PATH environment variable) to use a
cl-spec.sdoc file somewhere other than the default locations CLSPEC-
DATA-PATHNAME tries.")

(defun clspec-data-pathname ()
  "Find data/cl-spec.sdoc. Tries, in order: *CLSPEC-DATA-PATHNAME-
OVERRIDE*, the CL_AGENT_SPEC_PATH environment variable, the path
relative to the cl-agent ASDF system (works when running from source,
and from a `bin/cl-agent` built in place, since the system's root
pathname at build time is baked into the saved image), and finally a
path relative to the running executable itself (so a built
`bin/cl-agent` + its sibling `data/` directory keep working even if
copied somewhere ASDF no longer recognizes). Returns NIL, not an
error, if none of those pan out -- see LOOKUP-CL-SPEC-TEXT for how
that's reported to the model."
  (or (and *clspec-data-pathname-override* (probe-file *clspec-data-pathname-override*))
      (let ((override (env "CL_AGENT_SPEC_PATH"))) (and override (probe-file override)))
      (ignore-errors (probe-file (asdf:system-relative-pathname "cl-agent" "data/cl-spec.sdoc")))
      (ignore-errors
       (probe-file (merge-pathnames "../data/cl-spec.sdoc"
                                    (uiop:pathname-directory-pathname (uiop:argv0)))))))

(defvar *clspec-index* nil
  "NIL until first use; thereafter a hash table mapping an upcased
defined name (a string, e.g. \"CAR\") to a list of the :COM nodes that
define it. More than one entry is normal: \"LIST\" is both a function
and a system class, each its own :COM node. Built once by
CLSPEC-ENSURE-INDEX and kept for the life of the process -- the whole
document is a few megabytes, cheap to hold in memory, not cheap to
re-parse on every lookup.")

(defun clspec-split-names (name-string)
  "A :COM node's :NAME property is one string, possibly several names
separated by \", \" (\"car, cdr, caar, ...\"). Split and trim it."
  (mapcar (lambda (s) (string-trim " " s))
          (loop with start = 0
                for comma = (position #\, name-string :start start)
                collect (subseq name-string start comma)
                while comma do (setf start (1+ comma)))))

(defun find-child (node type)
  "Return the first child of NODE (a node, TYPE PLIST . CHILDREN) that
is itself a node of type TYPE, or NIL. (Not exported by metaspectre to
us -- we don't load metaspectre at runtime, see this file's header --
so this is cl-agent's own small reimplementation of the same idea.)"
  (find type (cddr node) :key (lambda (c) (and (consp c) (first c)))))

(defun clspec-walk-com-nodes (node fn)
  "Call FN on every :COM node found anywhere under NODE, depth-first.
Structure-agnostic on purpose (see output-spec.md's node catalog: :COM
nodes live inside a :DICTIONARY inside a :CHAPTER, but nothing here
needs to know that nesting to find them)."
  (when (consp node)
    (when (eq (first node) :com) (funcall fn node))
    (dolist (child (cddr node)) (clspec-walk-com-nodes child fn))))

(defun clspec-ensure-index ()
  "Return *CLSPEC-INDEX*, building it on first call from
CLSPEC-DATA-PATHNAME. Returns NIL (and leaves *CLSPEC-INDEX* NIL, so
the next call tries again -- e.g. after the file shows up) if the data
file can't be found."
  (or *clspec-index*
      (let ((path (clspec-data-pathname)))
        (when path
          (let ((table (make-hash-table :test 'equal))
                (document (with-open-file (in path) (read in))))
            (clspec-walk-com-nodes
             document
             (lambda (com)
               (dolist (name (clspec-split-names (getf (second com) :name)))
                 (push com (gethash (string-upcase name) table)))))
            (setf *clspec-index* table))))))

;;; --- rendering sdoc nodes as plain text ---
;;;
;;; This is deliberately not a full renderer (compare metaspectre's own
;;; src/render.lisp, which produces styled HTML and needs the whole
;;; cross-reference-resolution machinery to do it): cross-references
;;; (:secref/:figref/:chapref, and name references like :funref) are
;;; shown as their bare tag/name rather than resolved to a section
;;; number or hyperlink, and math is flattened to plain characters
;;; rather than real notation. That's a deliberate scope cut, not an
;;; oversight -- it's enough for a model to read a dictionary entry's
;;; Syntax/Description/Examples, which is the actual point of this
;;; tool, and resolving cross-references properly needs a whole-
;;; document pass metaspectre does once at render time, not something
;;; worth re-implementing for a quick lookup.

(defvar *clspec-in-code* nil
  "Bound to T while rendering inside a :CODE node, where (per
output-spec.md) whitespace is significant and must not be collapsed.")

(defun clspec-collapse-whitespace (string)
  "Collapse runs of spaces/tabs/newlines to a single space, the way
output-spec.md says consumers should treat whitespace outside :CODE.
No regex dependency needed for something this small."
  (if *clspec-in-code*
      string
      (with-output-to-string (out)
        (let ((in-run nil))
          (loop for ch across string
                do (if (member ch '(#\space #\tab #\newline #\return))
                       (unless in-run (write-char #\space out) (setf in-run t))
                       (progn (write-char ch out) (setf in-run nil))))))))

(defun clspec-render-children (children)
  "Render a list of ELEMENTs (strings, nodes, :PAR, or a symref
keyword under :secref/:figref/:chapref -- see CLSPEC-RENDER-NODE for
those) to one string, honoring :PAR as a paragraph break."
  (with-output-to-string (out)
    (dolist (child children)
      (cond
        ((eq child :par) (write-string (string #\Newline) out) (write-string (string #\Newline) out))
        ((stringp child) (write-string (clspec-collapse-whitespace child) out))
        ((keywordp child) nil) ; a bare symref outside :secref/:figref/:chapref shouldn't occur; ignore defensively
        ((consp child) (write-string (clspec-render-node child) out))))))

(defparameter *clspec-def-kind-labels*
  '(("function" . "Function") ("macro" . "Macro") ("special-operator" . "Special Operator")
    ("generic-function" . "Generic Function") ("method" . "Method") ("accessor" . "Accessor")
    ("setf" . "Setf-able place") ("type" . "Type") ("variable" . "Variable") ("constant" . "Constant"))
  "Maps a :DEF node's :KIND string to display text for its signature line.")

(defun clspec-render-def (node)
  "Render a :DEF node (see output-spec.md's :def entry) as one
signature line per defined name -- usually just one, but a \"Multi\"
entry (the car/cdr family is the extreme case, 30 names sharing one
:arglist/:values template) gets one line per name, all using that same
shared template, since that is what the shared template means."
  (let* ((plist (second node))
         (kind (getf plist :kind))
         (names (find-child node :names))
         (name-strings (cddr names))
         (arglist (find-child node :arglist))
         (values (find-child node :values))
         (new-value (find-child node :new-value)))
    (with-output-to-string (out)
      (cond
        ((member kind '("variable" "constant" "type") :test #'string=)
         (format out "~{~a~^, ~}~%" name-strings))
        ((string= kind "setf")
         (dolist (name name-strings)
           (format out "(setf (~a~@[ ~a~]) ~a)~%" name
                   (and arglist (clspec-render-children (cddr arglist)))
                   (if new-value (clspec-render-children (cddr new-value)) "new-value"))))
        (t (dolist (name name-strings)
             (format out "(~a~@[ ~a~])" name (and arglist (clspec-render-children (cddr arglist))))
             (when values (format out " => ~a" (clspec-render-children (cddr values))))
             (terpri out))))
      (when (getf plist :no-return) (format out "[does not return]~%"))
      (format out "~a" (or (cdr (assoc kind *clspec-def-kind-labels* :test #'string=)) kind)))))

(defun clspec-render-node (node)
  "Render one sdoc NODE (TYPE PLIST . CHILDREN) to plain text. See the
section comment above this function's definition point for scope."
  (let ((type (first node)) (plist (second node)) (children (cddr node)))
    (case type
      ;; Invisible: index/editorial/historical markers contribute no
      ;; visible text (output-spec.md says as much for the :idx* family).
      ((:idxref :idxtext :idxcode :idxkwd :idxterm :idxkeyref :idxpackref :idxexample
        :issue :endissue :comment :reviewer :editornote :label)
       "")
      (:part (format nil "~%### ~a~%~%~a" (getf plist :name) (clspec-render-children children)))
      (:def (clspec-render-def node))
      (:names (format nil "~{~a~^, ~}" children))
      (:arglist (clspec-render-children children))
      (:keyword (clspec-render-children children))
      (:code (let ((*clspec-in-code* t))
               (format nil "~%```~%~a~%```~%" (clspec-render-children children))))
      ((:tt) (format nil "`~a`" (clspec-render-children children)))
      ((:b :i :rm :param) (clspec-render-children children))
      ((:term :newterm :sym :funref :macref :specref :varref :typeref :packref
        :declref :conref :loopref :keyref :misc)
       (clspec-render-children children))
      (:kwd (format nil ":~a" (clspec-render-children children)))
      ((:secref :figref :chapref) (format nil "[see ~a]" (string-downcase (symbol-name (first children)))))
      (:nextfigure "[see the following figure]")
      (:list (format nil "~{- ~a~%~}" (mapcar #'clspec-render-node children)))
      (:item (clspec-render-children children))
      (:table (with-output-to-string (out)
                (when (getf plist :name) (format out "~%Table: ~a~%" (clspec-render-children (getf plist :name))))
                (dolist (row children)
                  (format out "~{~a~^ | ~}~%" (mapcar #'clspec-render-node (cddr row))))))
      (:row (clspec-render-children children))
      (:cell (clspec-render-children children))
      (:figure (clspec-render-children children))
      (:caption (format nil "Figure: ~a" (clspec-render-children children)))
      (:bnf (format nil "~a ::= ~a" (getf plist :name) (clspec-render-children children)))
      (:star (format nil "~a*" (clspec-render-children children)))
      (:plus (format nil "~a+" (clspec-render-children children)))
      (:one (format nil "~a¹" (clspec-render-children children)))
      (:curly (format nil "{~a}" (clspec-render-children children)))
      (:brac (format nil "[~a]" (clspec-render-children children)))
      (:paren (format nil "(~a)" (clspec-render-children children)))
      (:interleave (format nil "⟦~a⟧" (clspec-render-children children)))
      (:down (clspec-render-children children))
      (:metavar (format nil "<~a>" (clspec-render-children children)))
      (:br (string #\Newline))
      ((:math :displaymath :mrow :msup :msub :mfrac :msqrt :mtable :mtr :mtd :mspace)
       (clspec-render-children children))
      ((:mn :mi :mo :mtext) (clspec-render-children children))
      (:sub (clspec-render-children children))
      (:ang (format nil "<~a>" (clspec-render-children children)))
      ((:pronounced :hi-stress :lo-stress :in) (clspec-render-children children))
      (:bib (clspec-render-children children))
      (t (clspec-render-children children)))))

(defun clspec-render-com (com)
  "Render one :COM dictionary entry to readable plain text: a header
with its name(s) and :FTYPE, then each :PART in order."
  (let ((plist (second com)))
    (format nil "~a (~a)~%~a"
            (getf plist :name) (getf plist :ftype)
            (clspec-render-children (cddr com)))))

(defun lookup-cl-spec-text (name &key part)
  "Look up NAME (a string -- case-insensitive, e.g. \"car\", \"LOOP\",
\"defmacro\") in the ANSI Common Lisp standard. Returns a string:
either the rendered dictionary entry/entries (more than one when NAME
names more than one kind of thing, e.g. \"list\"), or, if NAME isn't a
defined name, a message naming the closest substring matches so the
caller can retry. If PART is given (e.g. \"Syntax\", \"Examples\"),
only parts whose name contains PART (case-insensitively) are included,
across all matching entries -- handy for a long entry like LOOP or
DEFCLASS when only one section is wanted.
Returns a plain explanatory string (never an error) when the data file
itself can't be found, so this is safe to expose as a tool unconditionally."
  (let ((index (clspec-ensure-index)))
    (unless index
      (return-from lookup-cl-spec-text
        (format nil "The Common Lisp spec data file isn't available (looked for data/cl-spec.sdoc). ~
                      Run scripts/build-clspec-data.sh to generate it; see that script's header comment.")))
    (let* ((key (string-upcase (string-trim ": " name)))
           (entries (gethash key index)))
      (cond
        (entries
         (format nil "~{~a~^~%~%---~%~%~}"
                 (mapcar (lambda (com)
                           (if part
                               (clspec-render-com
                                (list* (first com) (second com)
                                       (remove-if-not
                                        (lambda (c) (and (consp c) (eq (first c) :part)
                                                          (search (string-upcase part)
                                                                  (string-upcase (getf (second c) :name ""))
                                                                  :test #'char=)))
                                        (cddr com))))
                               (clspec-render-com com)))
                         entries)))
        (t (let ((candidates (loop for k being the hash-keys of index
                                    when (search key k) collect k)))
             (if candidates
                 (format nil "No exact match for ~s. Did you mean: ~{~a~^, ~}?" name (sort candidates #'string<))
                 (format nil "No match for ~s in the Common Lisp standard." name))))))))
