;;;; opsis-conditions-stub.lisp -- see opsis-conditions-stub.asd.
;;;;
;;;; cl-mcp (https://github.com/quasi/cl-mcp, which cl-agent depends on
;;;; for MCP client+server support, see src/mcp/) declares a dependency
;;;; on `opsis/conditions` purely to call one structured-logging
;;;; function, OPSIS/C:EMIT, at a handful of points in its server run
;;;; loop (server started/stopped, request received/failed). The real
;;;; `opsis` library isn't published anywhere ocicl or Quicklisp can
;;;; fetch it from, so rather than either (a) vendoring cl-mcp's source
;;;; to strip the dependency, which would drift from upstream, or (b)
;;;; losing those log lines, this file provides a small compatible
;;;; replacement: same package name, same EMIT signature, logging to
;;;; *ERROR-OUTPUT* when enabled.

(defpackage #:opsis/c
  (:use :cl)
  (:export #:emit #:*enabled*))

(in-package #:opsis/c)

(defvar *enabled* nil
  "When true, EMIT prints a line to *ERROR-OUTPUT*. Default NIL: cl-mcp's
lifecycle events are developer-diagnostic noise, not something cl-agent
users need to see by default.")

(defun emit (event &key source level message data)
  "Stand-in for opsis's structured EMIT call. EVENT is a keyword (e.g.
:server-started), SOURCE a string naming the emitting component, LEVEL
a severity keyword (:info/:error/...), MESSAGE a string, DATA arbitrary
extra plist/alist detail. Real `opsis` presumably supports subscribers,
filtering, structured sinks, etc; this stub only ever prints, and only
when *ENABLED*."
  (when *enabled*
    (format *error-output* "~&[opsis ~(~a~)/~(~a~)] ~a~@[: ~a~]~@[ ~s~]~%"
            (or level :info) (or source "?") event message data))
  (values))
