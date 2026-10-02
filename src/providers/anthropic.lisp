;;;; providers/anthropic.lisp -- Anthropic's Messages API.
;;;;
;;;; Unlike every other provider in this project, Anthropic does NOT
;;;; speak the OpenAI chat/completions wire format, so this class
;;;; subclasses LLM-PROVIDER directly rather than OPENAI-COMPATIBLE-
;;;; PROVIDER. The differences this file has to paper over, so the rest
;;;; of the codebase (repl.lisp, tools.lisp, ...) never has to know
;;;; about them:
;;;;
;;;;   - System prompt is a top-level `system` field, not a message
;;;;     with role "system".
;;;;   - There is no "tool" role. A tool result is sent back as a USER
;;;;     message whose content is a {"type":"tool_result",...} block.
;;;;   - Several tool results from one assistant turn must be grouped
;;;;     into a SINGLE user message, not sent as separate messages.
;;;;   - A tool definition is {"name":...,"description":...,
;;;;     "input_schema":...}, not OpenAI's nested
;;;;     {"type":"function","function":{...,"parameters":...}}.
;;;;   - A tool call's arguments arrive already parsed as a JSON object
;;;;     (the "input" field), not as a string you have to JSON-decode
;;;;     yourself the way OpenAI's `function.arguments` works.
;;;;   - `max_tokens` is a required request field.
;;;;
;;;; This mirrors openai-compatible.lisp's BUILD-REQUEST-BODY /
;;;; PARSE-CHAT-RESPONSE split for the same reason: so request/response
;;;; shaping is unit-testable without a network call.

(in-package :cl-agent)

(defparameter *anthropic-api-version* "2023-06-01")

(defclass anthropic-provider (llm-provider)
  ((api-key :initarg :api-key :accessor provider-api-key :initform nil)
   (base-url :initarg :base-url :accessor provider-base-url
             :initform "https://api.anthropic.com/v1")
   (max-tokens :initarg :max-tokens :accessor provider-max-tokens :initform 4096
               :documentation "Anthropic requires max_tokens on every
request; override if 4096 is too small/large for your use."))
  (:documentation "Anthropic's Claude models via the Messages API."))

(defmethod provider-default-model ((provider anthropic-provider)) "claude-sonnet-4-5")
(defmethod provider-display-name ((provider anthropic-provider)) "Anthropic")
(defmethod provider-api-key-env-var ((provider anthropic-provider)) "ANTHROPIC_API_KEY")

(defun anthropic-tool-schema (tool)
  (jobj "name" (tool-name tool)
        "description" (tool-description tool)
        "input_schema" (tool-parameters tool)))

(defun anthropic-split-system-and-messages (messages)
  "Pull leading/interspersed :role \"system\" messages out of MESSAGES
(joined with blank lines into one string, Anthropic has no notion of
multiple system turns) and group consecutive :role \"tool\" messages
into single Anthropic user turns with one tool_result block each.
Returns (values system-string anthropic-messages-list)."
  (let ((system-parts nil) (out nil) (pending-results nil))
    (flet ((flush-tool-results ()
             (when pending-results
               (push (jobj "role" "user"
                            "content" (nreverse pending-results))
                     out)
               (setf pending-results nil))))
      (dolist (m messages)
        (let ((role (getf m :role)))
          (cond
            ((string= role "system")
             (flush-tool-results)
             (push (getf m :content) system-parts))
            ((string= role "tool")
             (push (jobj "type" "tool_result"
                          "tool_use_id" (getf m :tool-call-id)
                          "content" (or (getf m :content) ""))
                   pending-results))
            ((and (string= role "assistant") (getf m :tool-calls))
             (flush-tool-results)
             (push (jobj "role" "assistant"
                          "content"
                          (append (when (and (getf m :content) (plusp (length (getf m :content))))
                                    (list (jobj "type" "text" "text" (getf m :content))))
                                  (mapcar (lambda (tc)
                                            (jobj "type" "tool_use"
                                                  "id" (getf tc :id)
                                                  "name" (getf tc :name)
                                                  "input" (getf tc :arguments)))
                                          (getf m :tool-calls))))
                   out))
            (t
             (flush-tool-results)
             (push (jobj "role" role "content" (or (getf m :content) "")) out)))))
      (flush-tool-results))
    (values (and system-parts (format nil "~{~a~^~%~%~}" (nreverse system-parts)))
            (nreverse out))))

(defmethod build-request-body ((provider anthropic-provider) messages tools)
  (multiple-value-bind (system anthropic-messages) (anthropic-split-system-and-messages messages)
    (apply #'jobj
           "model" (provider-model provider)
           "max_tokens" (provider-max-tokens provider)
           "messages" anthropic-messages
           (append (when system (list "system" system))
                   (when tools (list "tools" (mapcar #'anthropic-tool-schema tools)))))))

(defmethod parse-chat-response ((provider anthropic-provider) response)
  (let ((blocks (jget response "content"))
        (usage (jget response "usage")))
    (list :role "assistant"
          :content (let ((texts (loop for b in blocks
                                       when (string= (jget b "type") "text")
                                         collect (jget b "text"))))
                     (and texts (format nil "~{~a~}" texts)))
          :tool-calls (loop for b in blocks
                             when (string= (jget b "type") "tool_use")
                               collect (list :id (jget b "id")
                                             :name (jget b "name")
                                             :arguments (jget b "input")))
          ;; Anthropic's usage has no ready-made "total_tokens" field
          ;; (OpenAI's does); sum the two it does give.
          :usage (and usage (let ((in (jget usage "input_tokens")) (out (jget usage "output_tokens")))
                               (list :prompt-tokens in :completion-tokens out
                                     :total-tokens (and in out (+ in out))))))))

(defmethod chat ((provider anthropic-provider) messages tools)
  (let* ((url (concatenate 'string (provider-base-url provider) "/messages"))
         (headers (list (cons "x-api-key" (or (provider-api-key provider) ""))
                         (cons "anthropic-version" *anthropic-api-version*)))
         (body (build-request-body provider messages tools)))
    (multiple-value-bind (response status) (http-post-json url :body body :headers headers)
      (if (<= 200 status 299)
          (parse-chat-response provider response)
          (error 'provider-error :provider (provider-display-name provider)
                 :message (format nil "HTTP ~a: ~a" status
                                   (or (jpath response "error" "message") response)))))))

(register-provider-class :anthropic 'anthropic-provider)
