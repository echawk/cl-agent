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
    (:description "Check balanced parentheses in Lisp-like source text or an existing file path, reading strings, comments (; and #| |#), character literals and |symbols| as the reader does. When they do not balance it says exactly where (each extra \")\" and each \"(\" never closed, by line and column) and shows the fix fix-parens would make from the indentation. Use path right after writing a Lisp file or when loading it reports an EOF/reader error. A fast structural check only; use review-lisp for Mallet and compilation diagnostics."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Lisp-like source text; provide source or path, not both.")
                 "path" (jobj "type" "string" "description" "Existing text file to check; provide source or path, not both."))))
  (multiple-value-bind (source path) (quality-tool-source-or-path args "check-parens")
    (or (paren-fix-message (or source (uiop:read-file-string (paren-file-path path))))
        "Parentheses are balanced.")))

(defun paren-file-path (path)
  (let ((resolved (probe-file (expand-user-path path))))
    (unless (and resolved (not (uiop:directory-pathname-p resolved)))
      (error "No such file: ~a" path))
    resolved))

(defun write-file-text-as-edited (path text)
  "Put TEXT in the file at PATH: through its Lem buffer when it is open
there (the user's view stays current), saved; else straight to disk."
  (let ((open (and (lem-host-available-p)
                   (lem-call (lambda () (and (editor-find-buffer path) t))))))
    (if open
        (progn
          (editor-update-file path text)
          (editor-save-file path :by "agent-editor"))
        (write-string-atomically (paren-file-path path) text))))

(define-tool fix-parens (args)
    (:description "Fix the parentheses of Lisp source from its indentation, instead of counting them by hand: the closers at the ends of lines are rebuilt so each form closes where the next line's indentation says it ends, stray closers mid-line are dropped, and only the toplevel forms that are unbalanced are touched. Give source (returns the fixed text) or path (fixes the file, through its Lem buffer when open, and saves it). Reports each changed line. Use it whenever check-parens, a load, or eval-lisp reports unbalanced parentheses -- do not try to count them yourself. mode \"indent\" rebuilds every form even when balanced (to make the parens agree with the indentation)."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Lisp source text; provide source or path, not both.")
                 "path" (jobj "type" "string" "description" "A Lisp file to fix in place; provide source or path, not both.")
                 "mode" (jobj "type" "string" "enum" (list "auto" "indent")
                              "description" "auto (default): only unbalanced toplevel forms; indent: every form."))))
  (multiple-value-bind (source path) (quality-tool-source-or-path args "fix-parens")
    (let* ((text (or source (uiop:read-file-string (paren-file-path path))))
           (problems (paren-problems text)))
      (multiple-value-bind (fixed changes)
          (fix-parens text :mode (if (equal (jget args "mode") "indent") :indent :auto))
        (cond ((null changes)
               (if problems
                   (format nil "Could not fix: ~a." (describe-paren-problems problems))
                   "Parentheses are balanced; nothing to fix."))
              (t
               (when path (write-file-text-as-edited path fixed))
               (format nil "Fixed ~d line~:p~:[~*~; (~a)~]:~%~a~@[~%~%Fixed source:~%~a~]~:[~;~%~%Saved ~a.~]"
                       (length changes) problems (and problems (describe-paren-problems problems))
                       (describe-paren-fix changes)
                       (and source fixed)
                       path path)))))))
