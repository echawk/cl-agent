;;;; quality-tool.lisp -- expose the same automatic review to the model.

(in-package :cl-agent)

(defun quality-tool-source-or-path (args tool-name)
  "Return two values: source text and an optional file path from ARGS.

Quality tools accept exactly one input form so agents can check code before a
write or re-check the exact project file after a failed load/test."
  (let ((source (jget args "source"))
        (path (jget args "path")))
    (unless (or (stringp source) (stringp path))
      (error "~a requires exactly one string argument: \"source\" or \"path\"" tool-name))
    (when (and (stringp source) (stringp path))
      (error "~a accepts either \"source\" or \"path\", not both" tool-name))
    (when (and (stringp path) (zerop (length (string-trim " " path))))
      (error "~a path must be a non-empty string" tool-name))
    (values source path)))

(define-tool review-lisp (args)
    (:description "Review any Common Lisp: source text (a whole file or a snippet), a file path, or a source the lisp-source tool names as SYSTEM/PATH (e.g. cl-agent/src/repl.lisp -- your own source, even where only this built image still holds it). Runs the project's strict Mallet rules, reports a weighted smell score (lower is better), checks DEFSTAR/DECLAIM FTYPE claims, and compiles a disposable copy with SBCL; the macros, packages and classes compiling would define in this image are put back afterwards, so reviewing changed code never changes the running agent. Code using a package this image has not loaded is linted but reported as not compile-checked. Give package for a snippet without its own in-package (e.g. cl-agent). It never modifies the target file or leaves a FASL beside it. A nonzero score is advisory."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Common Lisp source to review; provide source or path, not both.")
                 "path" (jobj "type" "string" "description" "A Lisp file to review: a path on disk, or SYSTEM/PATH as lisp-source lists it; provide source or path, not both.")
                 "package" (jobj "type" "string" "description" "Package to compile in when the source has no in-package (default: the current one)."))))
  (multiple-value-bind (source path) (quality-tool-source-or-path args "review-lisp")
    (let ((package (jget args "package")))
      (format-lisp-review (if path
                              (review-lisp-file path :package package)
                              (review-lisp-source source :package package))))))

(define-tool check-parens (args)
    (:description "Check balanced parentheses in Lisp-like source text or an existing file path. Correctly ignores strings, line comments, and character literals. Use path immediately after writing a Lisp/Scheme-style file or when loading it reports an EOF/reader error. This is a fast structural check only; use review-lisp for Mallet and compilation diagnostics."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Lisp-like source text; provide source or path, not both.")
                 "path" (jobj "type" "string" "description" "Existing text file to check; provide source or path, not both."))))
  (multiple-value-bind (source path) (quality-tool-source-or-path args "check-parens")
    (let ((imbalance (if path (check-paren-balance-file path) (check-paren-balance source))))
      (if imbalance
          (paren-imbalance-message imbalance)
          "Parentheses are balanced."))))
