;;;; mcp/client.lisp -- cl-agent as an MCP *client*: connect to any
;;;; external MCP server and expose its tools as ordinary cl-agent
;;;; TOOLs (see tools.lisp), indistinguishable to the model from a
;;;; built-in tool like `shell`.
;;;;
;;;; This is deliberately a thin adapter, not a reimplementation: the
;;;; actual MCP wire protocol (JSON-RPC 2.0 over a subprocess's stdio,
;;;; newline-delimited) is handled entirely by cl-mcp/client
;;;; (https://github.com/quasi/cl-mcp), a small, separately-tested
;;;; (fiveam) MIT-licensed library. This file's whole job is
;;;; translating between cl-mcp.client's conventions and cl-agent's
;;;; own (see json-util.lisp's JALIST->HASH/JHASH->ALIST for the JSON-
;;;; representation half of that, and MCP-REMOTE-TOOL-NAME /
;;;; MCP-CONTENT-BLOCKS->TEXT below for the rest).
;;;;
;;;; Note on the package name: cl-mcp's ASDF system is "cl-mcp", but
;;;; ocicl's registry separately hosts an unrelated, also-published
;;;; "cl-mcp" by a different author -- if you ever re-pin this
;;;; dependency, install it with
;;;; `ocicl install git+https://github.com/quasi/cl-mcp`, NOT
;;;; `ocicl install cl-mcp`, or you will silently get the wrong
;;;; library. See ocicl.csv's existing cl-mcp entry and boot.lisp's
;;;; OCICL-PACKAGE-DIRECTORIES comment.

(in-package :cl-agent)

(defclass mcp-connection ()
  ((name :initarg :name :reader mcp-connection-name :type string)
   (client :initarg :client :reader mcp-connection-client
           :documentation "The underlying CL-MCP.CLIENT:MCP-CLIENT struct.")
   (tool-names :initarg :tool-names :accessor mcp-connection-tool-names :initform nil
               :documentation "Wire names (see MCP-REMOTE-TOOL-NAME) this
connection registered, so DISCONNECT-MCP-SERVER can clean them up."))
  (:documentation "Bookkeeping for one live connection to an external
MCP server: which cl-mcp.client object it is, and which cl-agent TOOLs
it contributed so they can be unregistered on disconnect."))

(defvar *mcp-connections* (make-hash-table :test 'equal)
  "Registry of live MCP client connections, keyed by the NAME given to
CONNECT-MCP-SERVER. Analogous to *TOOLS*/*PROVIDER-REGISTRY*.")

(defun mcp-remote-tool-name (server-name tool-name)
  "Wire name a tool from SERVER-NAME's TOOL-NAME is registered under:
\"mcp__SERVER-NAME__TOOL-NAME\" -- namespaced so two MCP servers that
happen to both expose a tool called e.g. \"search\" don't collide in
cl-agent's single flat *TOOLS* registry (this convention is cl-agent's
own choice, modeled on the same \"mcp__server__tool\" shape other MCP
hosts use for the same reason; see src/mcp/client.lisp's header)."
  (format nil "mcp__~a__~a" server-name tool-name))

(defun mcp-content-blocks->text (content-blocks)
  "CL-MCP.CLIENT:CALL-TOOL's :CONTENT is a list of MCP content blocks
-- alists with a \"type\" key, the common case being
((\"type\" . \"text\") (\"text\" . \"...\")). cl-agent's TOOL contract
(see tools.lisp) is \"return one string\", so this joins every text
block's text and ignores other content types (images, resource links,
...) for now -- true multi-modal tool results aren't something
cl-agent's provider layer threads through yet either."
  (format nil "~{~a~^~%~}"
          (loop for block in content-blocks
                for text = (cdr (assoc "text" block :test #'string=))
                when text collect text)))

(defun connect-mcp-server (name command)
  "Launch COMMAND (a list of strings, e.g. (\"npx\" \"-y\"
\"@modelcontextprotocol/server-filesystem\" \"/tmp\")) as an MCP
server subprocess, perform the MCP handshake, and register each tool
it advertises as a cl-agent TOOL (see MCP-REMOTE-TOOL-NAME for the
registered name). Re-running with the same NAME disconnects and
replaces any previous connection under that name. Returns the number
of tools registered. Signals MCP-ERROR, tagged with NAME, if the
subprocess can't be started or the handshake fails."
  (when (gethash name *mcp-connections*) (disconnect-mcp-server name))
  (handler-case
      (let* ((client (cl-mcp.client:make-client :name "cl-agent" :command command))
             (remote-tools (progn (cl-mcp.client:connect client) (cl-mcp.client:list-tools client)))
             (tool-names
               (let ((*registration-origin* (list :mcp name))
                     (*registration-owner* (format nil "mcp:~a" name)))
                 (mapcar
                  (lambda (rt)
                    (let ((remote-name (getf rt :name))
                          (wire-name (mcp-remote-tool-name name (getf rt :name))))
                      (register-tool
                       (make-instance 'tool
                                      :name wire-name
                                      :description (format nil "[MCP server ~a] ~a" name (or (getf rt :description) ""))
                                      :parameters (jalist->hash (or (getf rt :input-schema) (list (cons "type" "object"))))
                                      :metadata (list :remote-name remote-name :server name)
                                      :handler (lambda (args)
                                                 (mcp-content-blocks->text
                                                  (getf (cl-mcp.client:call-tool client remote-name (jhash->alist args))
                                                        :content)))))
                      wire-name))
                  remote-tools))))
        (setf (gethash name *mcp-connections*)
              (make-instance 'mcp-connection :name name :client client :tool-names tool-names))
        (publish-component :mcp-connection name
                           :owner (format nil "mcp:~a" name)
                           :origin (list :mcp name)
                           :provides tool-names
                           :metadata (list :command command))
        (length tool-names))
    (error (c)
      (error 'mcp-error :server-name name :message (princ-to-string c)))))

(defun disconnect-mcp-server (name)
  "Disconnect the MCP server connection registered under NAME and
unregister every tool it contributed. Returns T if there was a
connection to tear down, NIL if NAME wasn't connected."
  (let ((conn (gethash name *mcp-connections*)))
    (when conn
      (dolist (tool-name (mcp-connection-tool-names conn)) (unregister-tool tool-name))
      (unpublish-component :mcp-connection name)
      (retire-components-owned-by (format nil "mcp:~a" name))
      (ignore-errors (cl-mcp.client:disconnect (mcp-connection-client conn)))
      (remhash name *mcp-connections*)
      t)))

(defun list-mcp-connections ()
  "Return a list of (:name NAME :tools (WIRE-NAME...)) for every live
MCP server connection, for the /mcp REPL command and introspection."
  (loop for name being the hash-keys of *mcp-connections* using (hash-value conn)
        collect (list :name name :tools (mcp-connection-tool-names conn))))
