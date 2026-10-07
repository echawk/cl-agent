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
    (:description "Review Common Lisp supplied as source text or at an existing file path. Runs the project's strict Mallet rules, reports a weighted smell score (lower is better), checks DEFSTAR/DECLAIM FTYPE claims, and compiles a disposable copy with SBCL. Use path after writing or when a Lisp/Scheme-style test/load fails; it never modifies the target file or leaves a FASL beside it. A nonzero score is advisory."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Complete Common Lisp source to review; provide source or path, not both.")
                 "path" (jobj "type" "string" "description" "Existing Lisp source file to review; provide source or path, not both."))))
  (multiple-value-bind (source path) (quality-tool-source-or-path args "review-lisp")
    (format-lisp-review (if path (review-lisp-file path) (review-lisp-source source)))))

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
