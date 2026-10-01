;;;; providers/openai-compatible.lisp -- base class for any backend that
;;;; speaks the OpenAI /chat/completions wire format: REALLMS, OpenAI
;;;; itself, xAI/Grok, and Ollama's OpenAI-compatible endpoint all do.
;;;;
;;;; This class factors CHAT into three separately-overridable, and
;;;; separately UNIT-TESTABLE (see t/test-providers.lisp), pieces:
;;;;
;;;;   BUILD-REQUEST-BODY  provider + messages + tools -> JSON-able value
;;;;   (the actual HTTP POST, not a generic function -- see CHAT below)
;;;;   PARSE-CHAT-RESPONSE provider + decoded JSON -> normalized message
;;;;
;;;; A new OpenAI-compatible provider (xAI adds a vendor-specific field
;;;; to the request body, say) only needs to specialize BUILD-REQUEST-
;;;; BODY or PARSE-CHAT-RESPONSE, typically by calling CALL-NEXT-METHOD
;;;; and tweaking the result, rather than reimplementing CHAT's HTTP
;;;; plumbing and error handling from scratch.

(in-package :cl-agent)

(defclass openai-compatible-provider (llm-provider)
  ((base-url :initarg :base-url :accessor provider-base-url :initform nil
             :documentation "e.g. \"https://api.openai.com/v1\" -- no
trailing slash, CHAT-PATH is appended to it as-is.")
   (chat-path :initarg :chat-path :initform "/chat/completions" :accessor provider-chat-path)
   (api-key :initarg :api-key :accessor provider-api-key :initform nil)
   (extra-headers :initarg :extra-headers :initform nil :accessor provider-extra-headers
                  :documentation "Alist of additional (string . string)
request headers, for a provider that needs something beyond bearer
auth (org IDs, beta feature flags, etc).")
   (system-role :initarg :system-role :initform "system" :accessor provider-system-role
                :documentation "Some OpenAI-compatible backends want
\"developer\" instead of \"system\" for the leading instruction
message; override per-class if so."))
  (:documentation "Base class for providers using OpenAI's chat/completions
request/response shape. See REALLMS-PROVIDER, OPENAI-PROVIDER,
XAI-PROVIDER, and OLLAMA-PROVIDER for the thin concrete subclasses."))

(defun openai-message-json (message)
  "Normalized message plist (see CHAT's docstring in provider.lisp) ->
one JSON object in OpenAI's `messages` array shape."
  (let ((role (getf message :role)))
    (cond
      ((string= role "tool")
       (jobj "role" "tool"
             "tool_call_id" (getf message :tool-call-id)
             "content" (or (getf message :content) "")))
      ((and (string= role "assistant") (getf message :tool-calls))
       (jobj "role" "assistant"
             "content" (getf message :content)
             "tool_calls"
             (mapcar (lambda (tc)
                       (jobj "id" (getf tc :id)
                             "type" "function"
                             "function" (jobj "name" (getf tc :name)
                                               "arguments" (json-encode (getf tc :arguments)))))
                     (getf message :tool-calls))))
      (t (jobj "role" role "content" (or (getf message :content) ""))))))

(defgeneric build-request-body (provider messages tools)
  (:documentation "Build the JSON-able request body CHAT will POST.
Pure function of its arguments (no I/O) so it can be unit tested.")
  (:method ((provider openai-compatible-provider) messages tools)
    (apply #'jobj
           "model" (provider-model provider)
           "messages" (mapcar #'openai-message-json messages)
           (when tools (list "tools" (mapcar #'tool-json-schema tools))))))

(defgeneric parse-chat-response (provider response)
  (:documentation "Decoded JSON RESPONSE body -> normalized assistant
message plist (see CHAT's docstring). Pure function, unit-testable
against a canned response with no network access.")
  (:method ((provider openai-compatible-provider) response)
    (let* ((message (jpath response "choices" 0 "message"))
           (content (jget message "content"))
           (raw-calls (jget message "tool_calls")))
      (list :role "assistant"
            :content content
            :tool-calls
            (mapcar (lambda (tc)
                      (let ((fn (jget tc "function")))
                        (list :id (jget tc "id")
                              :name (jget fn "name")
                              :arguments (handler-case (json-decode (jget fn "arguments" "{}"))
                                           (error () (jobj))))))
                    raw-calls)))))

(defmethod chat ((provider openai-compatible-provider) messages tools)
  (unless (provider-base-url provider)
    (error 'provider-error :provider (provider-display-name provider)
           :message "no base-url set"))
  (let* ((url (concatenate 'string (provider-base-url provider) (provider-chat-path provider)))
         (headers (append (and (provider-api-key provider)
                                (list (cons "Authorization" (format nil "Bearer ~a" (provider-api-key provider)))))
                           (provider-extra-headers provider)))
         (body (build-request-body provider messages tools)))
    (multiple-value-bind (response status) (http-post-json url :body body :headers headers)
      (if (<= 200 status 299)
          (parse-chat-response provider response)
          (error 'provider-error :provider (provider-display-name provider)
                 :message (format nil "HTTP ~a: ~a" status
                                   (or (jpath response "error" "message") response)))))))
