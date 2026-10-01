;;;; opsis.asd -- see opsis-conditions-stub.lisp for the why.
;;;;
;;;; Named opsis.asd, not opsis-conditions-stub.asd, on purpose: ASDF's
;;;; directory-based system search resolves a slash-containing system
;;;; name like "opsis/conditions" as a SECONDARY system defined inside
;;;; "<part-before-the-slash>.asd" -- i.e. it looks for a file named
;;;; exactly opsis.asd, the same convention that lets cl-mcp/client be
;;;; found inside cl-mcp's own cl-mcp.asd. See boot.lisp's comment on
;;;; OCICL-PACKAGE-DIRECTORIES for the other half of this mechanism.
;; ASDF treats "opsis/conditions" as a secondary system of "opsis" (the
;; part before the slash) and implicitly requires a primary system by
;; that bare name to exist, even though nothing here calls for one
;; directly -- an empty placeholder satisfies that.
(asdf:defsystem "opsis" :components ())

(asdf:defsystem "opsis/conditions"
  :description "Minimal stand-in for the unpublished opsis/conditions
system (a structured-logging library), providing just the
OPSIS/C:EMIT call that cl-mcp's (github.com/quasi/cl-mcp)
src/server.lisp uses at MCP protocol lifecycle points. opsis itself
isn't published to ocicl/Quicklisp; see opsis-conditions-stub.lisp."
  :components ((:file "opsis-conditions-stub")))
