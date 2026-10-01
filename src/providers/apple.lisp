;;;; providers/apple.lisp -- extension point for Apple's on-device
;;;; models (the "Apple Intelligence" / Foundation Models framework).
;;;;
;;;; As of this writing Apple's on-device models are exposed only as a
;;;; Swift framework (FoundationModels, macOS 26 / iOS 26+), not as a
;;;; local HTTP server the way Ollama is -- so there is no URL this
;;;; file could point `drakma` at. Rather than fake support or skip the
;;;; provider entirely, this class defines the shape the integration
;;;; would take and shells out to a small bridge executable, so:
;;;;
;;;;   1. the provider list (and :provider :apple in config) is
;;;;      already wired up end-to-end, and
;;;;   2. anyone who writes a ~20-line Swift CLI that reads a JSON
;;;;      {system, messages} object on stdin and writes a JSON
;;;;      {content} object on stdout gets a working provider for free,
;;;;      with no changes to this file or anywhere else in the agent.
;;;;
;;;; (A Foundation Models bridge CLI is a reasonable afternoon project
;;;; -- see Apple's "Generating content and performing tasks with
;;;; Foundation Models" documentation -- but is out of scope here,
;;;; mirroring how Ollama is only testable on a machine with enough
;;;; free memory to run it; see README.md and t/test-ollama-integration.lisp.)
;;;;
;;;; Tool calling is NOT implemented for this bridge protocol; a
;;;; request with non-empty TOOLS signals an error naming what's
;;;; missing rather than silently ignoring the tools.

(in-package :cl-agent)

(defclass apple-provider (llm-provider)
  ((command :initarg :command :accessor provider-command
            :initform "apple-intelligence-bridge"
            :documentation "Executable (found via PATH, or an absolute
path) to run for each request. Receives a JSON object on stdin:
{\"model\": ..., \"system\": STRING-OR-NULL, \"messages\": [{\"role\":...,
\"content\":...}, ...]} and must print a JSON object on stdout:
{\"content\": STRING}."))
  (:documentation "Bring-your-own-bridge provider for Apple's
on-device Foundation Models. See this file's header comment."))

(defmethod provider-default-model ((provider apple-provider)) "default")
(defmethod provider-display-name ((provider apple-provider)) "Apple Intelligence")
;; No API key: this is purely local.

(defmethod chat ((provider apple-provider) messages tools)
  (when tools
    (error 'provider-error :provider (provider-display-name provider)
           :message "the apple-provider bridge protocol does not support tool calling yet -- extend CHAT on APPLE-PROVIDER (providers/apple.lisp) to add it once a bridge executable that supports tools exists."))
  (let* ((system-messages (remove-if-not (lambda (m) (string= (getf m :role) "system")) messages))
         (system (and system-messages (format nil "~{~a~^~%~%~}" (mapcar (lambda (m) (getf m :content)) system-messages))))
         (other-messages (remove-if (lambda (m) (string= (getf m :role) "system")) messages))
         (request (json-encode
                   (jobj "model" (provider-model provider)
                         "system" (or system :null)
                         "messages" (mapcar (lambda (m) (jobj "role" (getf m :role)
                                                                "content" (or (getf m :content) "")))
                                             other-messages)))))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (list (provider-command provider))
                           :input (make-string-input-stream request)
                           :output :string
                           :error-output :string
                           :ignore-error-status t)
      (declare (ignore error-output))
      (unless (zerop exit-code)
        (error 'provider-error :provider (provider-display-name provider)
               :message (format nil "bridge command ~s exited ~d (is it installed and on PATH?)"
                                 (provider-command provider) exit-code)))
      (list :role "assistant" :content (jget (json-decode output) "content") :tool-calls nil))))

(register-provider-class :apple 'apple-provider)
