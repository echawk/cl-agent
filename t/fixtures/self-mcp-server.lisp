;;;; t/fixtures/self-mcp-server.lisp -- runs cl-agent's own MCP server
;;;; mode (src/mcp/server.lisp) as a subprocess, restricted to the
;;;; shell tool for speed, so t/test-mcp.lisp can verify cl-agent's
;;;; MCP client connecting to cl-agent's own MCP server end-to-end.

(let* ((here (make-pathname :directory (pathname-directory *load-pathname*)))
       (project-root (merge-pathnames "../../" here)))
  (load (merge-pathnames "boot.lisp" project-root)))
(asdf:load-system "cl-agent")

(in-package :cl-agent)
(run-cl-agent-mcp-server :tools (list (find-tool "shell")))
