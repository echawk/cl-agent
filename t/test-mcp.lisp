;;;; t/test-mcp.lisp -- tests for src/mcp/client.lisp and
;;;; src/mcp/server.lisp. "Offline" in the sense the rest of t/ means
;;;; it (no network access, no LLM provider needed) but NOT mocked:
;;;; the client tests spawn a real subprocess (t/fixtures/demo-mcp-server.lisp)
;;;; and speak real MCP/JSON-RPC to it over stdio, and the server test
;;;; spawns cl-agent's own MCP server mode and connects cl-agent's own
;;;; MCP client to it -- a genuine round trip, not a stub.

(in-package :cl-agent)

(defparameter *demo-mcp-server-command*
  (list "sbcl" "--script" (namestring (asdf:system-relative-pathname "cl-agent" "t/fixtures/demo-mcp-server.lisp"))))

(deftest connect-mcp-server-registers-remote-tools ()
  (unwind-protect
       (let ((count (connect-mcp-server "demo" *demo-mcp-server-command*)))
         (check-equal count 2)
         (check (find-tool "mcp__demo__add"))
         (check (find-tool "mcp__demo__echo")))
    (disconnect-mcp-server "demo")))

(deftest mcp-tool-call-round-trips ()
  (unwind-protect
       (progn
         (connect-mcp-server "demo" *demo-mcp-server-command*)
         (check-equal (call-tool "mcp__demo__add" (jobj "a" 3 "b" 4)) "7")
         (check-equal (call-tool "mcp__demo__echo" (jobj "text" "hello mcp")) "hello mcp"))
    (disconnect-mcp-server "demo")))

(deftest mcp-tool-schema-is-usable-json-schema ()
  (unwind-protect
       (progn
         (connect-mcp-server "demo" *demo-mcp-server-command*)
         (let ((schema (tool-parameters (find-tool "mcp__demo__add"))))
           (check (hash-table-p schema) "remote alist-based schema was converted to cl-agent's hash-table convention")
           (check-equal (jget schema "type") "object")
           ;; Round-trips through JSON-ENCODE (this is what actually
           ;; gets sent to an LLM provider) without error.
           (check (stringp (json-encode (tool-json-schema (find-tool "mcp__demo__add")))))))
    (disconnect-mcp-server "demo")))

(deftest disconnect-mcp-server-unregisters-tools ()
  (connect-mcp-server "demo" *demo-mcp-server-command*)
  (check (disconnect-mcp-server "demo"))
  (check-equal (find-tool "mcp__demo__add") nil)
  (check-equal (disconnect-mcp-server "demo") nil "disconnecting an already-gone connection is a no-op, not an error"))

(deftest reconnecting-same-name-replaces-not-stacks ()
  (unwind-protect
       (progn
         (connect-mcp-server "demo" *demo-mcp-server-command*)
         (connect-mcp-server "demo" *demo-mcp-server-command*)
         (check-equal (length (list-mcp-connections)) 1))
    (disconnect-mcp-server "demo")))

(deftest connect-mcp-server-bad-command-signals-mcp-error ()
  (check-condition mcp-error (connect-mcp-server "bad" (list "definitely-not-a-real-executable-xyz"))))

(deftest mcp-remote-tool-name-is-namespaced ()
  (check-equal (mcp-remote-tool-name "foo" "bar") "mcp__foo__bar"))

(deftest mcp-content-blocks->text-joins-text-blocks ()
  (check-equal (mcp-content-blocks->text '((("type" . "text") ("text" . "a"))
                                            (("type" . "text") ("text" . "b"))))
               (format nil "a~%b")))

;;; --- server side: expose cl-agent's own tools, connect to self ---

(deftest mcp-server-tool-schema-converts-to-alist ()
  (let ((schema (mcp-server-tool-schema (find-tool "shell"))))
    (check (jalist-p schema))
    (check-equal (cdr (assoc "type" schema :test #'string=)) "object")))

(deftest mcp-server-end-to-end-self-connection ()
  ;; cl-agent's own MCP client connects to cl-agent's own MCP server
  ;; mode (see src/mcp/server.lisp), running as a separate subprocess
  ;; exposing just the shell tool -- the full round trip in one test.
  (let* ((fixture (asdf:system-relative-pathname "cl-agent" "t/fixtures/self-mcp-server.lisp")))
    (unwind-protect
         (progn
           (connect-mcp-server "self" (list "sbcl" "--script" (namestring fixture)))
           (check (find-tool "mcp__self__shell"))
           (let ((result (call-tool "mcp__self__shell" (jobj "command" "echo mcp-self-test-marker"))))
             (check (search "mcp-self-test-marker" result))))
      (disconnect-mcp-server "self"))))
