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
           (raw-calls (jget message "tool_calls"))
           (usage (jget response "usage")))
      (list :role "assistant"
            :content content
            :tool-calls
            (mapcar (lambda (tc)
                      (let ((fn (jget tc "function")))
                        (multiple-value-bind (arguments arguments-error)
                            (decode-json-object (jget fn "arguments" "{}"))
                          (list :id (jget tc "id")
                                :name (jget fn "name")
                                :arguments arguments
                                :arguments-error arguments-error))))
                    raw-calls)
            :usage (and usage (list :prompt-tokens (jget usage "prompt_tokens")
                                     :completion-tokens (jget usage "completion_tokens")
                                     :total-tokens (jget usage "total_tokens")))))))

(defun openai-provider-url-and-headers (provider)
  (unless (provider-base-url provider)
    (error 'provider-error :provider (provider-display-name provider) :message "no base-url set"))
  (values (concatenate 'string (provider-base-url provider) (provider-chat-path provider))
          (append (and (provider-api-key provider)
                       (list (cons "Authorization" (format nil "Bearer ~a" (provider-api-key provider)))))
                  (provider-extra-headers provider))))

(defun openai-model-identifiers (response)
  "Extract stable model names from the standard OpenAI `GET /models`
response.  A few compatible servers use `name` rather than `id`, so accept
that harmless variation too."
  (remove-duplicates
   (remove nil (mapcar (lambda (model) (or (jget model "id") (jget model "name")))
                       (jget response "data")))
   :test #'string=))

(defmethod provider-list-models ((provider openai-compatible-provider))
  (multiple-value-bind (chat-url headers) (openai-provider-url-and-headers provider)
    (declare (ignore chat-url))
    (multiple-value-bind (response status)
        (http-get-json (concatenate 'string (provider-base-url provider) "/models") :headers headers)
      (if (<= 200 status 299)
          (sort (openai-model-identifiers response) #'string<)
          (error 'provider-error :provider (provider-display-name provider)
                 :message (format nil "GET /models returned HTTP ~a: ~a" status
                                  (or (jpath response "error" "message") response)))))))

(defmethod provider-for-model ((provider openai-compatible-provider) model)
  (make-instance (class-name (class-of provider))
                 :model model
                 :base-url (provider-base-url provider)
                 :api-key (provider-api-key provider)
                 :extra-headers (provider-extra-headers provider)
                 :system-role (provider-system-role provider)))

(defmethod chat ((provider openai-compatible-provider) messages tools)
  (multiple-value-bind (url headers) (openai-provider-url-and-headers provider)
    (let ((body (build-request-body provider messages tools)))
      (multiple-value-bind (response status) (http-post-json url :body body :headers headers)
        (if (<= 200 status 299)
            (parse-chat-response provider response)
            (error 'provider-error :provider (provider-display-name provider)
                   :message (format nil "HTTP ~a: ~a" status
                                     (or (jpath response "error" "message") response))))))))

;;; --- streaming ---
;;;
;;; Server-Sent-Events framing: lines "data: {json}\n", a blank line
;;; between frames, terminated by a literal "data: [DONE]" line. Each
;;; {json} is shaped like a chat-completion response but with "delta"
;;; (a partial message) instead of "message" in each choice, and tool
;;; call arguments split across many chunks -- see PARSE-SSE-STREAM's
;;; docstring for the accumulation rules, verified against a real
;;; Ollama server before writing (see git log for this file).

(defgeneric build-stream-request-body (provider messages tools)
  (:documentation "Like BUILD-REQUEST-BODY but with \"stream\": true.
Default method reuses BUILD-REQUEST-BODY and adds just that one field
-- deliberately NOT ALSO adding `stream_options` to request usage data
in the stream, since not every OpenAI-compatible backend tolerates an
unrecognized field (see CHAT-STREAM's docstring in provider.lisp).")
  (:method ((provider openai-compatible-provider) messages tools)
    (let ((body (build-request-body provider messages tools)))
      (setf (gethash "stream" body) t)
      body)))

(defun sse-data-line-payload (line)
  "LINE's payload if it's an SSE \"data: ...\" line (the part after
\"data: \", with any trailing carriage return stripped), or NIL for a
blank keep-alive line or anything else -- used to skip non-data lines
(SSE allows blank lines between frames, and some servers send
`: comment` keep-alives) without trying to JSON-decode them."
  (when (and (>= (length line) 6) (string= line "data: " :end1 6))
    (string-right-trim '(#\return) (subseq line 6))))

(defun accumulate-tool-call-delta (table index id name arguments-fragment)
  "Fold one streamed tool-call delta into TABLE (a hash table keyed by
the wire INDEX field -- parallel tool calls are distinguished this
way, not by id). Per OpenAI's streaming format: the first chunk for a
given index carries ID and FUNCTION.NAME (NAME here); every chunk,
including that first one, carries a FUNCTION.ARGUMENTS fragment
(ARGUMENTS-FRAGMENT) to concatenate, since a model can emit its
arguments JSON one token at a time. Returns TABLE."
  (let ((entry (or (gethash index table) (list :id nil :name nil :arguments ""))))
    (when id (setf (getf entry :id) id))
    (when name (setf (getf entry :name) name))
    (when arguments-fragment (setf (getf entry :arguments) (concatenate 'string (getf entry :arguments) arguments-fragment)))
    (setf (gethash index table) entry))
  table)

(defun parse-sse-stream (stream on-delta)
  "Read an OpenAI-style SSE STREAM to completion (through its
\"data: [DONE]\" line, or end of stream) and return the normalized
ASSISTANT-MESSAGE plist CHAT-STREAM promises (see provider.lisp),
calling (FUNCALL ON-DELTA CHUNK) with each non-empty text fragment as
it's read off STREAM -- i.e. ON-DELTA fires incrementally, in real
time as the network delivers more of STREAM, not after this function
returns.

Pure enough to unit-test offline despite reading a STREAM: pass a
MAKE-STRING-INPUT-STREAM over a canned \"data: ...\" transcript (see
t/test-providers.lisp) instead of a real socket -- STREAM only needs
to support READ-LINE."
  (let ((content-parts nil) (tool-call-table (make-hash-table)) (usage nil))
    (loop for line = (read-line stream nil nil)
          while line
          for payload = (sse-data-line-payload line)
          when (and payload (plusp (length payload)) (not (string= payload "[DONE]")))
            do (let* ((chunk (json-decode payload))
                      (choice (first (jget chunk "choices")))
                      (delta (and choice (jget choice "delta"))))
                 (when (jget chunk "usage") (setf usage (jget chunk "usage")))
                 (when delta
                   (let ((text (jget delta "content")))
                     (when (and text (plusp (length text)))
                       (push text content-parts)
                       (funcall on-delta text)))
                   (dolist (tc (jget delta "tool_calls"))
                     (accumulate-tool-call-delta tool-call-table (jget tc "index") (jget tc "id")
                                                  (jget (jget tc "function") "name")
                                                  (jget (jget tc "function") "arguments"))))))
    (list :role "assistant"
          :content (and content-parts (format nil "~{~a~}" (nreverse content-parts)))
          :tool-calls (mapcar (lambda (index)
                                 (let ((entry (gethash index tool-call-table)))
                                   (multiple-value-bind (arguments arguments-error)
                                       (decode-json-object (getf entry :arguments))
                                     (list :id (getf entry :id) :name (getf entry :name)
                                           :arguments arguments
                                           :arguments-error arguments-error))))
                               (sort (loop for k being the hash-keys of tool-call-table collect k) #'<))
          :usage (and usage (list :prompt-tokens (jget usage "prompt_tokens")
                                   :completion-tokens (jget usage "completion_tokens")
                                   :total-tokens (jget usage "total_tokens"))))))

(defmethod chat-stream ((provider openai-compatible-provider) messages tools on-delta)
  (multiple-value-bind (url headers) (openai-provider-url-and-headers provider)
    (let ((body (build-stream-request-body provider messages tools)))
      (multiple-value-bind (stream status)
          (drakma:http-request url :method :post :content-type "application/json"
                                    :content (json-encode body) :additional-headers headers
                                    :want-stream t :connection-timeout 120
                                    :external-format-out :utf-8 :external-format-in :utf-8)
        (unless (<= 200 status 299)
          (let ((text (handler-case
                          (with-output-to-string (out)
                            (loop for line = (read-line stream nil nil) while line do (write-line line out)))
                        (error () ""))))
            (ignore-errors (close stream))
            (error 'provider-error :provider (provider-display-name provider)
                   :message (format nil "HTTP ~a: ~a" status text))))
        (unwind-protect (parse-sse-stream stream on-delta)
          (ignore-errors (close stream)))))))
