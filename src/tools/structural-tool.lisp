;;;; tools/structural-tool.lisp -- preview-only structural rewrite planning.

(in-package :cl-agent)

(define-tool structural-query (args)
    (:description "Find AST-aware structural matches in one existing file without modifying it. Results are anchored to an immutable file snapshot and include character/UTF-8 offsets plus matched text. Requires ast-grep installed on PATH."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "path" (jobj "type" "string" "description" "Existing file to inspect.")
                 "language" (jobj "type" "string" "description" "ast-grep language, for example javascript, python, rust, or html.")
                 "pattern" (jobj "type" "string" "description" "Structural ast-grep pattern."))
           "required" (list "path" "language" "pattern")))
  (multiple-value-bind (snapshot matches)
      (query-structural-file (jget args "path") (jget args "language") (jget args "pattern"))
    (format-structural-query snapshot matches)))

(define-tool structural-rewrite-plan (args)
    (:description "Preview an AST-aware rewrite of one existing file without modifying it. Uses ast-grep through Clasted, observes an immutable content-revision snapshot, rejects overlapping edits, and returns the full proposed file text. This tool is preview-only: inspect the plan, then use the normal guarded edit-file workflow to publish an intentional change. Requires ast-grep installed on PATH."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "path" (jobj "type" "string" "description" "Existing file to observe and rewrite.")
                 "language" (jobj "type" "string" "description" "ast-grep language, for example javascript, python, rust, or html.")
                 "pattern" (jobj "type" "string" "description" "Structural ast-grep pattern.")
                 "replacement" (jobj "type" "string" "description" "ast-grep rewrite template; may be empty to delete."))
           "required" (list "path" "language" "pattern" "replacement")))
  (format-structural-plan
   (plan-structural-rewrite (jget args "path") (jget args "language")
                            (jget args "pattern") (jget args "replacement"))))
