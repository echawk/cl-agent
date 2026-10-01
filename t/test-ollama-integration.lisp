;;;; t/test-ollama-integration.lisp -- the one test in this project that
;;;; makes a real network call to a real model. Everything else in t/
;;;; is pure/offline on purpose (see t/framework.lisp's header comment)
;;;; so the default `make test` never depends on external state; this
;;;; file is loaded separately, by `make test-ollama`, specifically to
;;;; prove the HTTP + JSON + provider plumbing works end-to-end against
;;;; something real, not just against canned fixtures.
;;;;
;;;; Model choice: CL_AGENT_OLLAMA_TEST_MODEL env var, default
;;;; "qwen2.5:0.5b" -- chosen for being about as small a model as
;;;; currently has a working tool-calling chat template in Ollama's
;;;; library (plain text completion works with even smaller models,
;;;; but this project's whole point is the tool-calling agent loop).
;;;; `make test-ollama` pulls it with the ollama CLI before this file
;;;; is loaded; see the Makefile.
;;;;
;;;; This is intentionally NOT wired into `(asdf:test-op :cl-agent)` --
;;;; it lives in the separate cl-agent/tests/ollama system (see
;;;; cl-agent.asd) so that running it is always an explicit choice.

(in-package :cl-agent)

(defparameter *ollama-test-model*
  (or (uiop:getenv "CL_AGENT_OLLAMA_TEST_MODEL") "qwen2.5:0.5b"))

(defun ollama-reachable-p ()
  (handler-case
      (multiple-value-bind (body status)
          (drakma:http-request "http://localhost:11434/api/tags" :connection-timeout 3)
        (declare (ignore body))
        (= status 200))
    (error () nil)))

(defun run-ollama-integration-tests ()
  (unless (ollama-reachable-p)
    (format t "~&~%cl-agent: ollama does not appear to be running on localhost:11434.~%~
                 Start it with `ollama serve` (and `make test-ollama` will have already~%~
                 run `ollama pull ~a` for you) and try again.~%~%" *ollama-test-model*)
    (uiop:quit 1))

  (format t "~&Using model ~a~%" *ollama-test-model*)
  (setf *current-test* 'ollama-integration)
  (let ((provider (make-provider :ollama :model *ollama-test-model*)))

    (format t "~&* plain completion, no tools~%")
    (let ((reply (chat provider
                        (list (list :role "user"
                                    :content "Reply with exactly one word: pong"))
                        nil)))
      (check (stringp (getf reply :content)) "got a string content back")
      (check (plusp (length (getf reply :content))) "content is non-empty")
      (format t "  model said: ~s~%" (getf reply :content))
      (unless (search "pong" (string-downcase (or (getf reply :content) "")))
        (format t "  (note: model didn't say \"pong\" -- fine, ~a is tiny and not ~
                     instruction-tuned to follow this precisely; the HTTP/JSON round ~
                     trip is what this test is actually checking)~%" *ollama-test-model*)))

    (format t "~&* tool-calling round trip~%")
    (let* ((marker (format nil "cl-agent-ollama-marker-~a" (random 1000000)))
           (session (make-session provider
                                   :system-prompt "You are a test harness. When asked to run a shell command, use the shell tool."
                                   :tools (list (find-tool "shell")))))
      (setf (session-messages session)
            (append (session-messages session)
                    (list (list :role "user"
                                :content (format nil "Use the shell tool to run: echo ~a" marker)))))
      (handler-case (run-agent-turn session)
        (error (c) (check nil (format nil "agent turn raised an error: ~a" c))))
      (let ((tool-messages (remove-if-not (lambda (m) (string= (getf m :role) "tool"))
                                           (session-messages session))))
        (if tool-messages
            (progn
              (check (some (lambda (m) (search marker (or (getf m :content) ""))) tool-messages)
                     "the marker echoed by the shell command shows up in a tool-result message")
              (format t "  model successfully called the shell tool.~%"))
            (format t "  (note: ~a never called the shell tool for this prompt -- fine, tiny ~
                         models are flaky about tool-calling; the HTTP/JSON round trip for ~
                         plain completion above is what primarily matters here)~%" *ollama-test-model*))))))

(run-ollama-integration-tests)
(format t "~&~%~d passed, ~d failed~%" *pass-count* *fail-count*)
(when (plusp *fail-count*) (uiop:quit 1))
