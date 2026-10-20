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
connection registered, so DISCONNECT-MCP-SERVER can clean them up.")
   (timeout :initarg :timeout :reader mcp-connection-timeout
            :documentation "Seconds each tools/call on this connection waits
for its response (see MCP-CALL-TOOL)."))
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

(defparameter *mcp-default-call-timeout* 30
  "Seconds a tools/call waits for its response when the connection sets
no :TIMEOUT of its own. 30 is cl-mcp.client's own fixed default, kept so
servers configured without :TIMEOUT behave exactly as before.")

(defun mcp-call-timeout (value)
  "VALUE as a tools/call timeout in seconds: NIL means
*MCP-DEFAULT-CALL-TIMEOUT*; anything but a positive real is an error."
  (cond ((null value) *mcp-default-call-timeout*)
        ((and (realp value) (plusp value)) value)
        (t (error "MCP :timeout must be a positive number of seconds, got ~s" value))))

(defun mcp-call-tool (client name arguments timeout)
  "CL-MCP.CLIENT:CALL-TOOL, but waiting up to TIMEOUT seconds for the
response. cl-mcp's CALL-TOOL always waits its internal %SEND-REQUEST's
30 s default, which is too short for servers that start a heavyweight
backend on first use -- REA (https://github.com/morluto/rea) allows
Ghidra 330 s just to start. So this sends the same tools/call request
itself and signals the same conditions CALL-TOOL does: MCP-SESSION-
CLOSED on timeout, MCP-PROTOCOL-ERROR on a JSON-RPC error, MCP-TOOL-
ERROR on isError:true. Returns the result's content blocks.

%SEND-REQUEST is internal to cl-mcp.client; re-check this function
against CALL-TOOL whenever ocicl.csv's cl-mcp pin changes."
  (let* ((response (cl-mcp.client::%send-request
                    client "tools/call"
                    `(("name" . ,name)
                      ("arguments" . ,(or arguments (make-hash-table :test #'equal))))
                    :timeout timeout))
         (err (cl-mcp.json-rpc:response-error response))
         (result (cl-mcp.json-rpc:response-result response))
         (content (cdr (assoc "content" result :test #'string=))))
    (when err
      (error 'cl-mcp.client.conditions:mcp-protocol-error
             :message (format nil "tools/call failed: ~a" (getf err :message))))
    (when (cdr (assoc "isError" result :test #'string=))
      (error 'cl-mcp.client.conditions:mcp-tool-error
             :tool-name name :content content
             :message (format nil "Tool ~a returned an error" name)))
    content))

(defun connect-mcp-server (name command &key timeout)
  "Launch COMMAND (a list of strings, e.g. (\"npx\" \"-y\"
\"@modelcontextprotocol/server-filesystem\" \"/tmp\")) as an MCP
server subprocess, perform the MCP handshake, and register each tool
it advertises as a cl-agent TOOL (see MCP-REMOTE-TOOL-NAME for the
registered name). Each call to one of those tools waits up to TIMEOUT
seconds (default *MCP-DEFAULT-CALL-TIMEOUT*) for the server's response.
Re-running with the same NAME disconnects and
replaces any previous connection under that name. Returns the number
of tools registered. Signals MCP-ERROR, tagged with NAME, if the
subprocess can't be started, the handshake fails, or TIMEOUT is invalid."
  (when (gethash name *mcp-connections*) (disconnect-mcp-server name))
  (handler-case
      (let* ((timeout (mcp-call-timeout timeout))
             (client (cl-mcp.client:make-client :name "cl-agent" :command command))
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
                                                  (mcp-call-tool client remote-name (jhash->alist args) timeout)))))
                      wire-name))
                  remote-tools))))
        (setf (gethash name *mcp-connections*)
              (make-instance 'mcp-connection :name name :client client :tool-names tool-names
                                             :timeout timeout))
        (publish-component :mcp-connection name
                           :owner (format nil "mcp:~a" name)
                           :origin (list :mcp name)
                           :provides tool-names
                           :metadata (list :command command :timeout timeout))
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
