;;;; mcp/server.lisp -- cl-agent as an MCP *server*: expose cl-agent's
;;;; own tool registry (shell, eval-lisp, write-extension,
;;;; lookup-cl-spec, plus anything an extension has added) to an
;;;; external MCP client -- Claude Code, Claude Desktop, or anything
;;;; else that speaks MCP.
;;;;
;;;; This directly delivers the "persistent REPL access, with lots of
;;;; tools" idea behind cl-mcp-server (github.com/quasi/cl-mcp-server)
;;;; without depending on it or re-implementing its 37 bespoke tools:
;;;; cl-agent already HAS a persistent, self-modifying Lisp image with
;;;; its own tool registry (see extensions.lisp/tools.lisp) -- the only
;;;; thing missing was a way for an external MCP client to reach it,
;;;; which is exactly what wrapping cl-mcp's SERVER half (the same
;;;; library src/mcp/client.lisp uses for the client half) provides, in
;;;; about sixty lines.
;;;;
;;;; Usage: `cl-agent --mcp-serve` runs this instead of the normal chat
;;;; REPL, speaking MCP over its own stdin/stdout -- the expected way
;;;; to run any stdio MCP server (an external client spawns it as a
;;;; subprocess; see e.g. Claude Code's / Claude Desktop's MCP server
;;;; config, which is just a command + args, exactly like
;;;; CONNECT-MCP-SERVER's own COMMAND argument in client.lisp).

(in-package :cl-agent)

(defun mcp-server-tool-schema (tool)
  "TOOL's JSON-Schema :PARAMETERS (a hash table, see tools.lisp),
converted to the alist shape CL-MCP:REGISTER-TOOL wants."
  (jhash->alist (tool-parameters tool)))

(defun mcp-server-tool-handler (tool)
  "A handler closure CL-MCP:REGISTER-TOOL can call: converts its alist
arguments to the hash table cl-agent's CALL-TOOL expects, and returns
the plain string CALL-TOOL returns -- CL-MCP wraps a string return
into a text content block automatically (see its tools.lisp
NORMALIZE-TOOL-RESULT), so no further wrapping is needed here."
  (lambda (alist-args) (call-tool (tool-name tool) (jalist->hash alist-args))))

(defun make-cl-agent-mcp-server (&key (name "cl-agent") (tools (list-tools)))
  "Build a CL-MCP:MCP-SERVER exposing TOOLS (default: every currently
registered cl-agent tool, see LIST-TOOLS) as MCP tools. Does not run
it -- see RUN-CL-AGENT-MCP-SERVER."
  (let ((server (cl-mcp:make-server :name name :version "0.1.0")))
    (dolist (tool tools server)
      (cl-mcp:register-tool server (tool-name tool)
                             :description (tool-description tool)
                             :schema (mcp-server-tool-schema tool)
                             :handler (mcp-server-tool-handler tool)))))

(defun run-cl-agent-mcp-server (&key (name "cl-agent") (tools (list-tools))
                                      (input *standard-input*) (output *standard-output*))
  "Run an MCP server exposing TOOLS over INPUT/OUTPUT (default:
this process's own stdio -- the normal arrangement, since an MCP
client spawns the server as a subprocess and talks to it over the
pipes it created). Blocks until EOF on INPUT. Signals MCP-ERROR,
tagged with NAME, on an unexpected failure."
  (handler-case
      (cl-mcp:run-server (make-cl-agent-mcp-server :name name :tools tools) :input input :output output)
    (error (c) (error 'mcp-error :server-name name :message (princ-to-string c)))))
