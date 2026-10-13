;;;; t/test-context-window.lisp -- context windows read from what model
;;;; servers advertise (providers/*.lisp PROVIDER-CONTEXT-WINDOW) and the
;;;; automatic compaction they drive (repl.lisp AUTO-COMPACT-IF-NEEDED).
;;;; A loopback hunchentoot plays the model server.

(in-package :cl-agent)

(defclass fake-model-server (hunchentoot:acceptor)
  ((respond :initarg :respond :reader fake-model-server-respond
            :documentation "(PATH BODY-TEXT) -> JSON text, or NIL for a 404.")
   (hits :initform 0 :accessor fake-model-server-hits))
  (:default-initargs :address "127.0.0.1" :access-log-destination nil :message-log-destination nil))

(defmethod hunchentoot:acceptor-dispatch-request ((server fake-model-server) request)
  (incf (fake-model-server-hits server))
  (setf (hunchentoot:content-type*) "application/json")
  (or (funcall (fake-model-server-respond server) (hunchentoot:script-name request)
               (hunchentoot:raw-post-data :request request :force-text t))
      (progn (setf (hunchentoot:return-code*) 404) "{}")))

(defmacro with-fake-model-server ((server url) respond &body body)
  "Run BODY with SERVER answering RESPOND at URL (http://127.0.0.1:PORT)."
  `(let ((,server nil))
     (loop for port = (+ 14700 (random 800))
           repeat 20
           do (handler-case
                  (progn (setf ,server (make-instance 'fake-model-server :port port :respond ,respond))
                         (hunchentoot:start ,server)
                         (return))
                (error () (setf ,server nil))))
     (forget-context-windows)
     (unwind-protect
          (let ((,url (format nil "http://127.0.0.1:~d" (hunchentoot:acceptor-port ,server))))
            ,@body)
       (hunchentoot:stop ,server)
       (forget-context-windows))))

;;; --- reading a listing ---

(deftest model-listings-advertise-windows-in-many-shapes ()
  (flet ((window (json) (model-entry-context-window (json-decode json))))
    (check-equal (window "{\"id\":\"a\",\"max_input_tokens\":131072,\"max_output_tokens\":8192}") 131072 "LiteLLM / REALLMS")
    (check-equal (window "{\"id\":\"a\",\"max_model_len\":32768}") 32768 "vLLM")
    (check-equal (window "{\"id\":\"a\",\"top_provider\":{\"context_length\":200000}}") 200000 "OpenRouter")
    (check-equal (window "{\"id\":\"a\",\"meta\":{\"n_ctx_train\":4096}}") 4096 "llama.cpp")
    (check-equal (window "{\"id\":\"a\",\"loaded_context_length\":8192,\"max_context_length\":32768}") 8192
                 "LM Studio: the loaded context wins")
    (check-equal (window "{\"id\":\"a\",\"context_length\":\"65536\"}") 65536 "a numeric string")
    (check-equal (window "{\"id\":\"a\",\"context_window\":131072.0}") 131072 "a float")
    (check (null (window "{\"id\":\"a\",\"owned_by\":\"openai\"}")))))

;;; --- OpenAI-compatible servers (REALLMS, vLLM, LM Studio, ...) ---

(deftest openai-compatible-windows-come-from-the-server-and-are-cached ()
  (with-fake-model-server (server url)
      (lambda (path body)
        (declare (ignore body))
        (and (string= path "/v1/models")
             "{\"data\":[{\"id\":\"small\",\"max_input_tokens\":4096},{\"id\":\"big\",\"context_length\":131072}]}"))
    (let ((provider (make-instance 'reallms-provider :base-url (format nil "~a/v1" url)
                                                     :api-key "test" :model "small")))
      (check-equal (provider-context-window provider) 4096)
      (check-equal (provider-context-window (provider-for-model provider "big")) 131072)
      (check (null (provider-context-window (provider-for-model provider "unlisted"))))
      (check-equal (fake-model-server-hits server) 1 "one listing serves every model, then the cache"))))

(deftest a-server-that-fails-is-not-asked-before-every-request ()
  (with-fake-model-server (server url) (lambda (path body) (declare (ignore path body)) nil)
    (let ((provider (make-instance 'reallms-provider :base-url (format nil "~a/v1" url)
                                                     :api-key "test" :model "small")))
      (check (null (provider-context-window provider)))
      (check (null (provider-context-window provider)))
      (check-equal (fake-model-server-hits server) 1))))

(deftest known-models-fall-back-when-the-server-says-nothing ()
  (with-fake-model-server (server url)
      (lambda (path body) (declare (ignore body)) (and (string= path "/v1/models") "{\"data\":[{\"id\":\"gpt-4o\"}]}"))
    (check-equal (provider-context-window
                  (make-instance 'openai-provider :base-url (format nil "~a/v1" url) :api-key "test" :model "gpt-4o"))
                 128000))
  (with-fake-model-server (server url) (lambda (path body) (declare (ignore path body)) nil)
    (check-equal (provider-context-window
                  (make-instance 'anthropic-provider :base-url (format nil "~a/v1" url) :api-key "test"
                                                     :model "claude-opus-5-5"))
                 200000 "every Claude model, not only the names in a table")))

;;; --- Ollama ---

(deftest ollama-windows-prefer-the-running-context ()
  (with-fake-model-server (server url)
      (lambda (path body)
        (cond ((string= path "/api/ps")
               "{\"models\":[{\"name\":\"loaded:latest\",\"model\":\"loaded:latest\",\"context_length\":8192}]}")
              ((string= path "/api/show")
               (let ((model (jget (json-decode body) "model")))
                 (cond ((equal model "tuned") "{\"parameters\":\"temperature 0.2\\nnum_ctx 2048\",\"model_info\":{\"llama.context_length\":131072}}")
                       ((equal model "plain") "{\"model_info\":{\"qwen2.context_length\":32768}}")
                       (t "{\"model_info\":{\"llama.context_length\":131072}}"))))))
    (let ((provider (make-instance 'ollama-provider :base-url (format nil "~a/v1" url) :model "loaded")))
      (check-equal (provider-context-window provider) 8192 "a loaded model reports what it runs with")
      (check-equal (provider-context-window (provider-for-model provider "tuned")) 2048 "num_ctx")
      (check-equal (provider-context-window (provider-for-model provider "plain")) 32768
                   "otherwise the trained context length"))))

;;; --- compaction sized to land under the limit ---

(defclass test-window-provider (ollama-provider)
  ((window :initarg :window :reader test-window)))
(defmethod provider-context-window ((provider test-window-provider)) (test-window provider))

(defmacro with-fake-summary (&body body)
  `(let ((complete (symbol-function 'session-complete)))
     (unwind-protect
          (progn (setf (symbol-function 'session-complete)
                       (lambda (&rest ignored) (declare (ignore ignored)) "Summary of the earlier work."))
                 ,@body)
       (setf (symbol-function 'session-complete) complete))))

(deftest auto-compaction-lands-under-the-limit-and-does-not-repeat ()
  (let ((session (make-session (make-instance 'test-window-provider :window 12000)
                               :tools nil :context-compaction-threshold 0.5)))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i below 80 collect (list :role (if (evenp i) "user" "assistant")
                                                     :content (make-string 400 :initial-element #\x)))))
    (with-fake-summary
      (check (auto-compact-if-needed session) "over the limit: compacts")
      (check (<= (estimated-context-tokens session) 6000) "and lands under it")
      (check (null (auto-compact-if-needed session)) "so the next request does not compact again"))))

(deftest auto-compaction-with-a-low-threshold-still-compacts ()
  ;; The verbatim tail used to be a quarter of the window regardless of the
  ;; threshold, so below 0.25 it kept everything and compaction did nothing.
  (let ((session (make-session (make-instance 'test-window-provider :window 100000)
                               :tools nil :context-compaction-threshold 0.1)))
    (setf (session-messages session)
          (append (session-messages session)
                  (loop for i below 60 collect (list :role (if (evenp i) "user" "assistant")
                                                     :content (make-string 1000 :initial-element #\x)))))
    (with-fake-summary
      (check (auto-compact-if-needed session))
      (check (<= (estimated-context-tokens session) 10000)))))

(deftest auto-compaction-says-once-when-tool-schemas-alone-are-too-big ()
  (let* ((session (make-session (make-instance 'test-window-provider :window 1000)
                                :tools (list-tools) :context-compaction-threshold 0.8))
         (output (make-string-output-stream))
         (summarized nil))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "hi"))))
    (let ((complete (symbol-function 'session-complete)))
      (unwind-protect
           (progn
             (setf (symbol-function 'session-complete)
                   (lambda (&rest ignored) (declare (ignore ignored)) (setf summarized t) "x"))
             (let ((*standard-output* output))
               (check (null (auto-compact-if-needed session)))
               (check (null (auto-compact-if-needed session)))))
        (setf (symbol-function 'session-complete) complete)))
    (check (not summarized) "no pointless summarization request")
    (check-equal (count-matches "tool schemas alone" (get-output-stream-string output)) 1)))
