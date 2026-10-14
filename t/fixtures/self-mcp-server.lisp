;;;; t/fixtures/self-mcp-server.lisp -- runs cl-agent's own MCP server
;;;; stack as a subprocess, restricted to the shell tool for speed, so
;;;; t/test-mcp.lisp can verify cl-agent's MCP client connecting to
;;;; cl-agent's own MCP server end-to-end.
;;;;
;;;; SBCL --script deliberately skips the user's init file.  Keep this fixture
;;;; deliberately small: it exercises the MCP protocol, not the full agent
;;;; application dependency graph.

(let* ((here (make-pathname :directory (pathname-directory *load-pathname*)))
       (project-root (merge-pathnames "../../" here)))
  (load (merge-pathnames "boot.lisp" project-root))
  (dolist (system '("shasht" "bordeaux-threads" "cl-mcp" "ironclad" "babel" "sexp-store"))
    ;; ASDF does not exist until BOOT.LISP has loaded, and LOAD reads this
    ;; enclosing form before evaluating it. Resolve LOAD-SYSTEM at runtime.
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") system))
  (unless (find-package :cl-agent)
    (defpackage :cl-agent (:use :cl)))
  (dolist (source '("src/conditions.lisp"
                    "src/events.lisp"
                    "src/components.lisp"
                    "src/json-util.lisp"
                    "src/guard.lisp"
                    "src/tools.lisp"
                    "src/mcp/server.lisp"))
    (load (merge-pathnames source project-root))))

(in-package :cl-agent)
(defvar *debugger-enabled* nil)
(define-tool shell (args)
    (:description "Fixture shell used only to test the MCP tool round trip."
     :parameters (jobj "type" "object"
                       "properties" (jobj "command" (jobj "type" "string"))
                       "required" (list "command")))
  (jget args "command"))
(run-cl-agent-mcp-server :tools (list (find-tool "shell")))
