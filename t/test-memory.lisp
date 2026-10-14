;;;; t/test-memory.lisp -- what the agent remembers across sessions (memory.lisp).

(in-package :cl-agent)

(deftest memories-are-kept-updated-and-forgotten ()
  (with-temp-config-dir ()
    (let ((out (call-tool "remember" (jobj "key" "test-command" "body" "make test")))) (check (search "Remembered test-command" out) out))
    (check (search "Updated test-command"
                   (call-tool "remember" (jobj "key" "Test-Command" "body" "make test (sets CL_AGENT_CONFIG_DIR)")))
           "the same key, any case, updates")
    (call-tool "remember" (jobj "key" "user-style" "body" "Prefers terse commit messages." "scope" "global"
                                "tags" (list "style")))
    (check-equal (length (all-memory-entries)) 2 "no duplicate")
    (check-equal (mapcar (lambda (entry) (getf entry :scope)) (all-memory-entries)) '(:project :global) "both scopes")
    (let ((out (call-tool "recall" (jobj "query" "config_dir")))) (check (search "CL_AGENT_CONFIG_DIR" out) out))
    (let ((out (call-tool "recall" (jobj "tag" "style")))) (check (search "user-style" out) out))
    (let ((out (call-tool "recall" (jobj "query" "nope")))) (check (search "Nothing remembered" out) out))
    (let ((out (call-tool "forget" (jobj "id" "user-style")))) (check (search "Forgot user-style (global)" out) out))
    (let ((out (call-tool "forget" (jobj "id" "user-style")))) (check (search "Nothing remembered has" out) out))
    (let ((out (call-tool "remember" (jobj "key" "  " "body" "x")))) (check (search "Give the memory's key" out) out))))

(deftest every-request-carries-the-memories-not-the-history ()
  (with-temp-config-dir ()
    (with-noop-tool
      (memory-remember "build" "Run make build before release.")
      (let* ((frontend (make-instance 'steer-frontend))
             (session (steer-session frontend
                                     (list (lambda () (steer-tool-call-message))
                                           (lambda () (list :role "assistant" :content "done" :tool-calls nil))))))
        (setf (session-messages session)
              (append (session-messages session) (list (list :role "user" :content "go"))))
        (check-equal (getf (run-agent-turn session) :content) "done")
        (let ((requests (steer-seen (session-provider session))))
          (check-equal (length requests) 2)
          (dolist (request requests)
            (check (search "build: Run make build before release." (getf (first request) :content))
                   "in the system message of every request, the second too")))
        (check (not (search "What you remember" (getf (first (session-messages session)) :content)))
               "never written into the session's own history")
        (setf (setinka:config :memory (session-settings session)) "off")
        (check-equal (with-memory-note session (session-provider-messages session))
                     (session-provider-messages session)
                     "the memory setting turns it off")))))
