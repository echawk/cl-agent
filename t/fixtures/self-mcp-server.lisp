;;;; t/fixtures/self-mcp-server.lisp -- runs cl-agent's own MCP server
;;;; stack as a subprocess, restricted to the shell tool for speed, so
;;;; t/test-mcp.lisp can verify cl-agent's MCP client connecting to
;;;; cl-agent's own MCP server end-to-end.
;;;;
;;;; SBCL --script deliberately skips the user's init file. Load only the
;;;; server's real source dependencies here instead of the whole CL-AGENT
;;;; system: the latter also loads unrelated UI, Skills, and LSP dependencies
;;;; and would make this offline protocol fixture depend on whatever happens
;;;; to be configured in a developer's Quicklisp init.

(let* ((here (make-pathname :directory (pathname-directory *load-pathname*)))
       (project-root (merge-pathnames "../../" here)))
  (load (merge-pathnames "boot.lisp" project-root))
  (dolist (system '("shasht" "bordeaux-threads" "cl-mcp"))
    ;; ASDF does not exist until BOOT.LISP has loaded, and LOAD reads this
    ;; enclosing form before evaluating it. Resolve LOAD-SYSTEM at runtime
    ;; instead of using an ASDF: package prefix that the reader cannot yet see.
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") system))
  (unless (find-package :cl-agent)
    (defpackage :cl-agent (:use :cl)))
  (dolist (source '("src/conditions.lisp"
                    "src/events.lisp"
                    "src/components.lisp"
                    "src/json-util.lisp"
                    "src/tools.lisp"
                    "src/tools/shell.lisp"
                    "src/mcp/server.lisp"))
    (load (merge-pathnames source project-root))))

(in-package :cl-agent)
(run-cl-agent-mcp-server :tools (list (find-tool "shell")))
