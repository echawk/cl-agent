;;;; A live test against a maintained, published npm MCP server -- not a fixture.

(in-package :cl-agent)

(defun external-mcp-filesystem-command ()
  (let ((root (asdf:system-relative-pathname "cl-agent" "t/fixtures/")))
    (list "npx" "--yes" "@modelcontextprotocol/server-filesystem@2025.12.18"
          (namestring root))))

(deftest published-filesystem-mcp-server-round-trip ()
  "Exercise discovery and an actual read through npm's published filesystem server."
  (unwind-protect
       (progn
         (connect-mcp-server "external-filesystem" (external-mcp-filesystem-command))
         (check (find-tool "mcp__external-filesystem__read_file")
                "published filesystem server exposes read_file")
         (let ((text (call-tool "mcp__external-filesystem__read_file"
                                (jobj "path"
                                      (namestring (asdf:system-relative-pathname
                                                   "cl-agent" "t/fixtures/demo-mcp-server.lisp"))))))
           (check (search "tiny real MCP server" text)
                  "read_file returns content from the published server")))
    (disconnect-mcp-server "external-filesystem")))
