;;;; tools/mcp-tool.lisp -- exposes src/mcp/client.lisp's MCP-client
;;;; machinery to the model itself, the same way tools/extensions-tool.lisp
;;;; exposes the self-modification machinery: connecting to a new MCP
;;;; server mid-conversation ("the user just mentioned a Postgres MCP
;;;; server they want me to use") is as much a self-extension act as
;;;; writing a new tool is, so it gets the same treatment -- a tool the
;;;; agent can call itself, not just a CLI/config-time-only feature.

(in-package :cl-agent)

(define-tool connect-mcp-server (args)
    (:description "Connect to an external MCP (Model Context Protocol) server, launched as a subprocess, and make every tool it advertises available for you to call -- each appears in your tool list as mcp__NAME__toolname. Use list-mcp-servers first to see what's already connected. Re-connecting under the same name replaces the previous connection."
     :parameters (jobj "type" "object"
                        "properties"
                        (jobj "name" (jobj "type" "string" "description" "A short name for this connection, e.g. \"filesystem\" or \"postgres\". Used as the mcp__NAME__... prefix on its tools.")
                              "command" (jobj "type" "array" "items" (jobj "type" "string")
                                               "description" "The subprocess command and arguments, e.g. [\"npx\", \"-y\", \"@modelcontextprotocol/server-filesystem\", \"/tmp\"]."))
                        "required" (list "name" "command")))
  (handler-case
      (let ((count (connect-mcp-server (jget args "name") (jget args "command"))))
        (format nil "Connected to MCP server ~s: ~d tool(s) registered." (jget args "name") count))
    (mcp-error (c) (format nil "~a" c))))

(define-tool disconnect-mcp-server (args)
    (:description "Disconnect a previously-connected MCP server by name and remove the tools it contributed."
     :parameters (jobj "type" "object"
                        "properties" (jobj "name" (jobj "type" "string"))
                        "required" (list "name")))
  (if (disconnect-mcp-server (jget args "name"))
      (format nil "Disconnected ~s." (jget args "name"))
      (format nil "No MCP server connected under the name ~s." (jget args "name"))))

(define-tool list-mcp-servers (args)
    (:description "List currently connected MCP servers and the tools each one contributed.")
  (let ((connections (list-mcp-connections)))
    (if connections
        (format nil "~{~{~a: ~{~a~^, ~}~}~^~%~}"
                (mapcar (lambda (c) (list (getf c :name) (getf c :tools))) connections))
        "No MCP servers currently connected.")))
