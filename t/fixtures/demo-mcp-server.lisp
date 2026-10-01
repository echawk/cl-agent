;;;; t/fixtures/demo-mcp-server.lisp -- a tiny real MCP server, run as a
;;;; subprocess by t/test-mcp.lisp, so the MCP client tests exercise a
;;;; genuine external process over real stdio JSON-RPC rather than a
;;;; mock. Not part of cl-agent itself -- a standalone script using
;;;; only cl-mcp directly (see boot.lisp's bootstrap, reused here via
;;;; the project root computed from this file's own location).

(let* ((here (make-pathname :directory (pathname-directory *load-pathname*)))
       (project-root (merge-pathnames "../../" here)))
  (load (merge-pathnames "boot.lisp" project-root)))
(asdf:load-system "cl-mcp")

(in-package :cl-mcp)

(let ((server (make-server :name "cl-agent-test-demo-server")))
  (register-tool server "add"
                  :description "Add two numbers"
                  :schema '(("type" . "object")
                            ("properties" . (("a" . (("type" . "number")))
                                              ("b" . (("type" . "number")))))
                            ("required" . ("a" "b")))
                  :handler (lambda (args)
                             (format nil "~a"
                                     (+ (cdr (assoc "a" args :test #'string=))
                                        (cdr (assoc "b" args :test #'string=))))))
  (register-tool server "echo"
                  :description "Echo back the given text"
                  :schema '(("type" . "object")
                            ("properties" . (("text" . (("type" . "string")))))
                            ("required" . ("text")))
                  :handler (lambda (args) (cdr (assoc "text" args :test #'string=))))
  (run-server server))
