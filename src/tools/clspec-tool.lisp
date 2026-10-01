;;;; tools/clspec-tool.lisp -- exposes src/clspec.lisp's lookup as a
;;;; tool, so the model can check what the ANSI standard actually says
;;;; about a function/macro/variable/type instead of relying on
;;;; (possibly imprecise) memory of it.

(in-package :cl-agent)

(define-tool lookup-cl-spec (args)
    (:description "Look up a name (function, macro, special operator, variable, constant, or type) in the ANSI Common Lisp standard and return its dictionary entry (Syntax, Arguments and Values, Description, Examples, etc). Use this to check exact argument order, return values, or edge-case behavior instead of guessing -- e.g. lookup-cl-spec(\"loop\") or lookup-cl-spec(\"the\"). If the name isn't found, the result lists close substring matches to retry with."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "name" (jobj "type" "string" "description" "The symbol name to look up, e.g. \"car\", \"defmacro\", \"loop\". Case-insensitive.")
                 "part" (jobj "type" "string" "description" "Optional: only return parts whose heading contains this (case-insensitive), e.g. \"examples\" or \"syntax\" -- useful to shorten a long entry like LOOP or DEFCLASS."))
           "required" (list "name")))
  (lookup-cl-spec-text (jget args "name") :part (jget args "part")))
