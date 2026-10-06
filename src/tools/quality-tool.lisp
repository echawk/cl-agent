;;;; quality-tool.lisp -- expose the same automatic review to the model.

(in-package :cl-agent)

(define-tool review-lisp (args)
    (:description "Review Common Lisp source before presenting or saving it. Runs the project's strict Mallet rules, reports a weighted smell score (lower is better), checks that every function has a DEFSTAR or DECLAIM FTYPE claim, and compiles the source with SBCL to expose compiler diagnostics. A nonzero score is advisory: minimize it, but code may retain justified violations. Always call this on Common Lisp code you generate outside eval-lisp/write-extension; those two tools invoke it automatically."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "source" (jobj "type" "string" "description" "Complete Common Lisp source to review."))
           "required" (list "source")))
  (let ((source (jget args "source")))
    (unless (stringp source)
      (error "review-lisp requires a string \"source\" argument"))
    (format-lisp-review (review-lisp-source source))))
