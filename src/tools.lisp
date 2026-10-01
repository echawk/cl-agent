;;;; tools.lisp -- the TOOL class, the tool registry, and DEFINE-TOOL.
;;;;
;;;; A "tool" here means exactly what every current LLM function-calling
;;;; API means by it: a name, a human-readable description, a
;;;; JSON-Schema describing its arguments, and a handler function the
;;;; agent runs locally when the model asks to call it. Providers each
;;;; translate the registry's TOOL objects into their own wire format
;;;; (see providers/openai-compatible.lisp's TOOL-JSON-SPEC and
;;;; providers/anthropic.lisp's method on the same generic function).
;;;;
;;;; This is one of the two extension surfaces an extension file is
;;;; expected to use (the other is hooks.lisp): call DEFINE-TOOL (or
;;;; REGISTER-TOOL directly) to give the model a brand new capability.

(in-package :cl-agent)

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string
         :documentation "Wire name the model uses to call this tool.
Must match [a-zA-Z0-9_-]+ -- most providers are picky about this.")
   (description :initarg :description :reader tool-description :type string
                :documentation "Shown to the model. Be specific about
when to use (and not use) the tool; this is effectively prompt text.")
   (parameters :initarg :parameters :reader tool-parameters
               :initform (jobj "type" "object" "properties" (jobj) "required" nil)
               :documentation "A JSON-Schema object (built with JOBJ,
or any hash table) describing the tool's arguments, in the same shape
OpenAI's function-calling `parameters` field expects. Every provider
in this project is responsible for translating this into its own
wire shape if it differs (see providers/anthropic.lisp).")
   (handler :initarg :handler :reader tool-handler :type function
            :documentation "A function of one argument -- a hash table
of parsed call arguments, as returned by JSON-DECODE -- that performs
the tool's effect and returns a STRING to show the model as the
result. May signal any condition; CALL-TOOL catches it (see below)."))
  (:documentation "A capability exposed to the LLM. See DEFINE-TOOL for
the usual way to create one; see REGISTER-TOOL to add an instance you
built some other way (e.g. one whose handler needs to close over some
state) to the registry."))

(defmethod print-object ((tool tool) stream)
  (print-unreadable-object (tool stream :type t)
    (format stream "~a" (tool-name tool))))

(defvar *tools* (make-hash-table :test 'equal)
  "Registry of all known tools, keyed by TOOL-NAME.")

(defun register-tool (tool)
  "Add TOOL to the registry, replacing any existing tool with the same
name. Returns TOOL. This is how an extension (or providers.lisp,
or tools/shell.lisp) makes a capability available to the model;
registering a tool does NOT by itself make every provider send it on
every request -- see SESSION-TOOLS in repl.lisp if you want to curate
which tools are offered."
  (setf (gethash (tool-name tool) *tools*) tool))

(defun unregister-tool (name)
  "Remove the tool named NAME (a string) from the registry, if present."
  (remhash name *tools*))

(defun find-tool (name)
  "Look up a registered tool by NAME (a string). Returns NIL, not an
error, if not found -- use CALL-TOOL if you want TOOL-NOT-FOUND
signalled instead."
  (gethash name *tools*))

(defun list-tools ()
  "Return all registered TOOL instances, in no particular order."
  (loop for tool being the hash-values of *tools* collect tool))

(defmacro define-tool (name (args-var) (&key description parameters) &body body)
  "Define and register a tool in one step. NAME is a symbol; its
STRING-DOWNCASEd name is used as the wire name. Inside BODY, ARGS-VAR
is bound to the hash table of parsed call arguments (use JGET to pull
fields out of it); BODY's return value (coerced with PRINC-TO-STRING
if it isn't already a string) becomes the tool result shown to the
model. ARGS-VAR is automatically declared ignorable, so a tool that
doesn't need any arguments doesn't need to mention it -- BODY runs
inside a PROGN (not directly as a lambda body), so do NOT add your own
(declare ...) at the start of BODY; it will not compile.

Example:

  (define-tool word-count (args)
      (:description \"Count words in a string.\"
       :parameters (jobj \"type\" \"object\"
                          \"properties\" (jobj \"text\" (jobj \"type\" \"string\"))
                          \"required\" (list \"text\")))
    (format nil \"~d words\" (length (uiop:split-string (jget args \"text\")))))"
  (let ((wire-name (string-downcase (string name))))
    `(register-tool
      (make-instance 'tool
                      :name ,wire-name
                      :description ,description
                      ,@(when parameters `(:parameters ,parameters))
                      :handler (lambda (,args-var)
                                 (declare (ignorable ,args-var))
                                 (let ((.result. (progn ,@body)))
                                   (if (stringp .result.) .result. (princ-to-string .result.))))))))

(defun call-tool (name arguments)
  "Run the tool named NAME (a string) with ARGUMENTS (a hash table,
typically produced by JSON-DECODE-ing the model's tool-call payload).
Always returns a STRING: either the handler's result, or a readable
description of whatever went wrong. A tool handler error is caught and
turned into text like \"Error running TOOL: ...\" rather than
propagating, because the point of a tool call, in an agent loop, is to
hand the MODEL something it can read and react to -- an unhandled
Lisp condition here would otherwise kill the whole REPL over (say) a
single bad shell command. Signals TOOL-NOT-FOUND (which the REPL loop
also reports as text to the model, so it can try a different tool
name) if NAME isn't registered."
  (let ((tool (or (find-tool name) (error 'tool-not-found :name name))))
    (handler-case (funcall (tool-handler tool) arguments)
      (error (c)
        (format nil "Error running ~a: ~a" name c)))))

(defun tool-json-schema (tool)
  "OpenAI/REALLMS/xAI/Ollama-shaped {\"type\":\"function\",\"function\":{...}}
wrapper around TOOL. Anthropic uses a different top-level shape; see
ANTHROPIC-TOOL-SCHEMA in providers/anthropic.lisp."
  (jobj "type" "function"
        "function" (jobj "name" (tool-name tool)
                          "description" (tool-description tool)
                          "parameters" (tool-parameters tool))))
