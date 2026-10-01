(in-package :cl-agent)

(deftest registry-knows-all-built-in-providers ()
  (dolist (name '(:reallms :openai :xai :ollama :anthropic :apple :apfel))
    (check (assoc name (list-providers)) (format nil "~a is registered" name))))

(deftest make-provider-unknown-name-signals ()
  (check-condition provider-not-found (make-provider :definitely-not-a-real-provider)))

(deftest make-provider-resolves-default-model ()
  (let ((p (make-provider :ollama)))
    (check-equal (provider-model p) (provider-default-model p))))

(deftest make-provider-explicit-model-overrides-default ()
  (let ((p (make-provider :ollama :model "custom-model")))
    (check-equal (provider-model p) "custom-model")))

(deftest make-provider-no-key-needed-for-ollama ()
  ;; Must not signal MISSING-API-KEY even though no key is supplied.
  (check (make-provider :ollama)))

(deftest make-provider-explicit-key-bypasses-env ()
  (let ((p (make-provider :openai :api-key "sk-explicit-test-key")))
    (check-equal (provider-api-key p) "sk-explicit-test-key")))

(deftest make-provider-api-key-env-override ()
  ;; :api-key-env lets config.lisp point a provider at a non-default
  ;; env var name (see src/config.lisp's :API-KEY-ENV doc) without
  ;; needing a new provider subclass.
  (let ((var "CL_AGENT_TEST_ALT_KEY_XYZ123"))
    (unwind-protect
         (progn
           #+sbcl (progn (require :sb-posix) (funcall (find-symbol "SETENV" :sb-posix) var "alt-value" 1))
           (let ((p (make-provider :openai :api-key-env var)))
             (check-equal (provider-api-key p) "alt-value")))
      (forget-env var))))

(deftest make-provider-missing-key-signals ()
  ;; Register a throwaway provider requiring a near-certainly-unset
  ;; env var, so this test doesn't depend on OPENAI_API_KEY etc. being
  ;; absent from whatever environment `make test` runs in.
  (defclass test-needs-key-provider (openai-compatible-provider) ()
    (:default-initargs :base-url "http://example.invalid"))
  (defmethod provider-default-model ((p test-needs-key-provider)) "x")
  (defmethod provider-api-key-env-var ((p test-needs-key-provider))
    "CL_AGENT_TEST_DEFINITELY_UNSET_KEY_XYZ123")
  (register-provider-class :test-needs-key 'test-needs-key-provider)
  (check-condition missing-api-key (make-provider :test-needs-key)))

(deftest openai-build-request-body-shape ()
  (let* ((p (make-provider :ollama))
         (body (build-request-body p
                                    (list (list :role "system" :content "sys")
                                          (list :role "user" :content "hello"))
                                    (list (find-tool "shell")))))
    (check-equal (jget body "model") (provider-model p))
    (check-equal (length (jget body "messages")) 2)
    (check-equal (jget (first (jget body "messages")) "role") "system")
    (check-equal (jget (first (jget body "tools")) "type") "function"
                 "shell tool is offered in OpenAI function-call shape")))

(deftest openai-build-request-body-omits-tools-key-when-none-offered ()
  (let* ((p (make-provider :ollama))
         (body (build-request-body p (list (list :role "user" :content "hi")) nil)))
    (check-equal (jget body "tools" :absent) :absent)))

(deftest openai-parse-chat-response-plain-text ()
  (let* ((p (make-provider :ollama))
         (raw (json-decode "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi there\"}}]}"))
         (msg (parse-chat-response p raw)))
    (check-equal (getf msg :role) "assistant")
    (check-equal (getf msg :content) "hi there")
    (check-equal (getf msg :tool-calls) nil)))

(deftest openai-parse-chat-response-tool-call-arguments-are-decoded ()
  (let* ((p (make-provider :ollama))
         (raw (json-decode "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}"))
         (msg (parse-chat-response p raw))
         (tc (first (getf msg :tool-calls))))
    (check-equal (getf tc :id) "c1")
    (check-equal (getf tc :name) "shell")
    (check-equal (jget (getf tc :arguments) "command") "ls"
                 "the double-JSON-encoded arguments string was decoded into a real object")))

(deftest openai-message-json-round-trips-assistant-tool-call ()
  (let* ((msg (list :role "assistant" :content nil
                     :tool-calls (list (list :id "c1" :name "shell" :arguments (jobj "command" "ls")))))
         (wire (openai-message-json msg)))
    (check-equal (jget wire "role") "assistant")
    (check-equal (jget (first (jget wire "tool_calls")) "id") "c1")
    (check-equal (jget (jget (first (jget wire "tool_calls")) "function") "name") "shell")))

(deftest openai-message-json-tool-result-shape ()
  (let ((wire (openai-message-json (list :role "tool" :tool-call-id "c1" :content "output"))))
    (check-equal (jget wire "role") "tool")
    (check-equal (jget wire "tool_call_id") "c1")
    (check-equal (jget wire "content") "output")))

;;; --- Anthropic: a genuinely different wire format, see providers/anthropic.lisp ---

(deftest anthropic-pulls-system-out-of-messages ()
  (let* ((p (make-provider :anthropic :api-key "x"))
         (body (build-request-body p (list (list :role "system" :content "be nice")
                                            (list :role "user" :content "hi"))
                                    nil)))
    (check-equal (jget body "system") "be nice")
    (check-equal (length (jget body "messages")) 1 "the system message is not also in the messages array")
    (check-equal (jget (first (jget body "messages")) "role") "user")))

(deftest anthropic-requires-max-tokens ()
  (let* ((p (make-provider :anthropic :api-key "x"))
         (body (build-request-body p (list (list :role "user" :content "hi")) nil)))
    (check (jget body "max_tokens"))))

(deftest anthropic-tool-schema-uses-input-schema-not-parameters ()
  (let ((schema (anthropic-tool-schema (find-tool "shell"))))
    (check-equal (jget schema "name") "shell")
    (check (jget schema "input_schema"))
    (check-equal (jget schema "parameters" :absent) :absent
                 "Anthropic's field is input_schema, not OpenAI's parameters")))

(deftest anthropic-tool-result-becomes-user-message-with-block ()
  (let* ((p (make-provider :anthropic :api-key "x"))
         (body (build-request-body p
                                    (list (list :role "user" :content "hi")
                                          (list :role "assistant" :content nil
                                                :tool-calls (list (list :id "t1" :name "shell"
                                                                         :arguments (jobj "command" "ls"))))
                                          (list :role "tool" :tool-call-id "t1" :content "out"))
                                    nil))
         (last-message (car (last (jget body "messages")))))
    (check-equal (jget last-message "role") "user")
    (let ((block (first (jget last-message "content"))))
      (check-equal (jget block "type") "tool_result")
      (check-equal (jget block "tool_use_id") "t1")
      (check-equal (jget block "content") "out"))))

(deftest anthropic-multiple-tool-results-grouped-into-one-message ()
  (let* ((p (make-provider :anthropic :api-key "x"))
         (body (build-request-body p
                                    (list (list :role "tool" :tool-call-id "a" :content "1")
                                          (list :role "tool" :tool-call-id "b" :content "2"))
                                    nil)))
    (check-equal (length (jget body "messages")) 1 "two consecutive tool results become ONE user turn")
    (check-equal (length (jget (first (jget body "messages")) "content")) 2)))

(deftest anthropic-parse-chat-response-text-and-tool-use ()
  (let* ((p (make-provider :anthropic :api-key "x"))
         (raw (json-decode "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"shell\",\"input\":{\"command\":\"pwd\"}}]}"))
         (msg (parse-chat-response p raw))
         (tc (first (getf msg :tool-calls))))
    (check-equal (getf msg :content) "ok")
    (check-equal (getf tc :id) "t2")
    (check-equal (jget (getf tc :arguments) "command") "pwd"
                 "Anthropic's \"input\" is already a decoded object, not a JSON-string-of-a-string")))
