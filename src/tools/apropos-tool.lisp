;;;; tools/apropos-tool.lisp -- exposes src/apropos.lisp's search as a
;;;; tool, so the model can check whether something it's about to
;;;; write with write-extension already exists -- in cl-agent's own
;;;; code or in one of the utility libraries already loaded in this
;;;; image (alexandria, serapeum, iterate, trivia -- see cl-agent.asd)
;;;; -- instead of guessing or reimplementing it from scratch.

(in-package :cl-agent)

(define-tool lisp-apropos (args)
    (:description "Search every loaded Lisp package for a function, macro, variable, or class whose name contains query (case-insensitive substring match -- the practical equivalent of Hoogle-by-name, since Lisp has no type-signature search). This image already has alexandria, serapeum, iterate, and trivia loaded alongside plain Common Lisp and cl-agent's own code -- search before writing a new tool or extension with write-extension, so you reuse an existing function instead of reimplementing it. Returns package:name, kind, lambda-list, and the first line of its docstring for each match, e.g. lisp-apropos(\"flatten\") or lisp-apropos(\"string-join\")."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "query" (jobj "type" "string" "description" "Substring to search symbol names for, e.g. \"flatten\", \"string-join\", \"hash-table\".")
                 "package" (jobj "type" "string" "description" "Optional: restrict the search to one package, e.g. \"alexandria\" or \"cl-agent\"."))
           "required" (list "query")))
  (lisp-apropos-text (jget args "query") :package (jget args "package")))
