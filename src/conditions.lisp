;;;; conditions.lisp -- condition types used throughout cl-agent.
;;;;
;;;; Keeping these in one place (rather than ad-hoc ERROR calls) means
;;;; callers -- including extension code written by the agent itself --
;;;; can HANDLER-CASE on a specific, documented condition instead of
;;;; parsing error strings.

(in-package :cl-agent)

(define-condition cl-agent-error (error)
  ()
  (:documentation "Base condition for all cl-agent-signalled errors.
Catch this if you want to handle \"anything cl-agent's own code raised\"
without also catching unrelated Lisp errors (unbound variables, etc.)."))

(define-condition provider-error (cl-agent-error)
  ((provider :initarg :provider :reader provider-error-provider
             :documentation "The LLM-PROVIDER instance (or name) involved.")
   (message :initarg :message :initform "" :reader provider-error-message))
  (:report (lambda (c stream)
             (format stream "Provider error (~a): ~a"
                     (provider-error-provider c) (provider-error-message c))))
  (:documentation "Signalled when talking to an LLM backend fails: a
non-2xx HTTP status, an unparseable response body, a missing API key,
etc."))

(define-condition provider-not-found (cl-agent-error)
  ((name :initarg :name :reader provider-not-found-name))
  (:report (lambda (c stream)
             (format stream "No provider registered under the name ~s.~%~
                              Known providers: ~{~a~^, ~}"
                     (provider-not-found-name c)
                     (mapcar #'car (and (fboundp 'list-providers) (funcall 'list-providers))))))
  (:documentation "Signalled by MAKE-PROVIDER when asked for an unknown
provider keyword. Not fatal to the extensibility story: register a new
provider class with REGISTER-PROVIDER-CLASS and the name becomes valid."))

(define-condition missing-api-key (provider-error)
  ((env-var :initarg :env-var :reader missing-api-key-env-var))
  (:report (lambda (c stream)
             (format stream "Provider ~a needs an API key. Set the ~a ~
                              environment variable (or pass :api-key ~
                              explicitly to MAKE-PROVIDER)."
                     (provider-error-provider c) (missing-api-key-env-var c))))
  (:documentation "Signalled when a provider that requires an API key
does not have one available from the environment or explicit config."))

(define-condition tool-not-found (cl-agent-error)
  ((name :initarg :name :reader tool-not-found-name))
  (:report (lambda (c stream)
             (format stream "No tool registered under the name ~s." (tool-not-found-name c))))
  (:documentation "Signalled by CALL-TOOL for an unknown tool name."))

(define-condition tool-execution-error (cl-agent-error)
  ((tool-name :initarg :tool-name :reader tool-execution-error-tool-name)
   (original-condition :initarg :original-condition :initform nil
                        :reader tool-execution-error-original-condition))
  (:report (lambda (c stream)
             (format stream "Tool ~s raised an error: ~a"
                     (tool-execution-error-tool-name c)
                     (or (tool-execution-error-original-condition c) "unknown error"))))
  (:documentation "Wraps any condition signalled by a tool's handler
function. CALL-TOOL catches tool handler errors and turns them into
this condition (and, in the normal agent loop, into a tool-result
message the model can see and recover from -- see repl.lisp)."))

(define-condition frontend-not-found (cl-agent-error)
  ((name :initarg :name :reader frontend-not-found-name))
  (:report (lambda (c stream)
             (format stream "No UI frontend registered under the name ~s.~%~
                              Known frontends: ~{~a~^, ~}"
                     (frontend-not-found-name c)
                     (mapcar #'car (and (fboundp 'list-frontends) (funcall 'list-frontends))))))
  (:documentation "Signalled by MAKE-FRONTEND for an unknown UI
keyword (see src/ui/frontend.lisp). Not fatal to the extensibility
story: REGISTER-FRONTEND-CLASS makes a new name valid, the same
pattern as PROVIDER-NOT-FOUND/REGISTER-PROVIDER-CLASS."))

(define-condition mcp-error (cl-agent-error)
  ((server-name :initarg :server-name :reader mcp-error-server-name)
   (message :initarg :message :initform "" :reader mcp-error-message))
  (:report (lambda (c stream) (format stream "MCP server ~s: ~a" (mcp-error-server-name c) (mcp-error-message c))))
  (:documentation "Signalled when connecting to, or calling a tool on,
an external MCP server fails (src/mcp/client.lisp), or when starting
cl-agent's own MCP server fails (src/mcp/server.lisp). Wraps whatever
condition cl-mcp/client or cl-mcp itself signalled, tagged with the
server NAME from config/the connect-mcp-server call, so callers can
catch one condition type without depending on cl-mcp's own package."))

(define-condition extension-error (cl-agent-error)
  ((path :initarg :path :reader extension-error-path)
   (original-condition :initarg :original-condition :initform nil
                        :reader extension-error-original-condition))
  (:report (lambda (c stream)
             (format stream "Failed to load extension ~a: ~a"
                     (extension-error-path c)
                     (or (extension-error-original-condition c) "unknown error"))))
  (:documentation "Signalled when LOAD-EXTENSION-FILE fails to compile
or load an extension. The extension system catches this so that one
broken extension file does not prevent the agent from starting."))
