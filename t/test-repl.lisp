(in-package :cl-agent)

(deftest default-prompt-named-tools-are-registered ()
  ;; Keep the prose capability guide honest. These are the concrete tool
  ;; names promised in *DEFAULT-SYSTEM-PROMPT*; Lisp functions mentioned as
  ;; eval-lisp examples are intentionally not included here.
  (dolist (name '("shell" "eval-lisp" "write-scratch-file" "write-extension"
                  "ask-llm" "list-models" "lisp-apropos" "lookup-cl-spec"
                  "review-lisp" "load-asdf-system" "connect-mcp-server"
                  "disconnect-mcp-server" "list-mcp-servers"))
    (check (find-tool name) (format nil "prompt promises registered tool ~a" name))))

(deftest subagent-and-project-explorer-tools-are-registered ()
  (check (find-tool "delegate-task"))
  (check (find-tool "explore-project")))

(deftest subagents-receive-read-only-investigation-tools ()
  (let ((names (mapcar #'tool-name (subagent-investigation-tools))))
    (dolist (name '("shell" "read-file" "read-file-range" "lisp-apropos" "review-lisp" "check-parens"))
      (check (member name names :test #'string=) (format nil "worker gets ~a" name)))
    (dolist (name '("write-file" "edit-file" "delegate-task" "explore-project"))
      (check (not (member name names :test #'string=)) (format nil "worker excludes ~a" name)))))

(deftest dispatch-slash-command-not-a-command-passthrough ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (check-equal (dispatch-slash-command session "hello there") :not-a-command)))

(deftest dispatch-slash-command-unknown-command-keeps-repl-running ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (check (dispatch-slash-command session "/definitely-not-a-real-command"))))

(deftest slash-exit-and-quit-return-nil ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (check-equal (dispatch-slash-command session "/exit") nil)
    (check-equal (dispatch-slash-command session "/quit") nil)))

(deftest slash-call-invokes-a-tool-with-json-args ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/call shell {\"command\": \"echo slash-call-test-marker\"}"))
    (check (search "slash-call-test-marker" (get-output-stream-string output)))))

(deftest slash-call-with-no-args-defaults-to-empty-object ()
  (define-tool test-repl-no-args-tool (args) (:description "d") (format nil "~d keys" (hash-table-count args)))
  (let ((session (make-session (make-instance 'ollama-provider)))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/call test-repl-no-args-tool"))
    (check (search "0 keys" (get-output-stream-string output))))
  (unregister-tool "test-repl-no-args-tool"))

(deftest slash-call-unknown-tool-returns-actionable-feedback ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (check (dispatch-slash-command session "/call no-such-tool-xyz {}")))
    (check (search "does not exist" (get-output-stream-string output)))))

(deftest slash-tools-lists-session-tools ()
  (let* ((session (make-session (make-instance 'ollama-provider) :tools (list (find-tool "shell"))))
         (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/tools"))
    (check (search "shell" (get-output-stream-string output)))))

(defclass test-model-menu-provider (llm-provider) ())
(defmethod provider-default-model ((provider test-model-menu-provider))
  (declare (ignore provider))
  "alpha")
(defmethod provider-list-models ((provider test-model-menu-provider))
  (declare (ignore provider))
  '("alpha" "beta"))

(deftest slash-model-with-no-argument-lists-live-models ()
  (let ((session (make-session (make-instance 'test-model-menu-provider :model "alpha")))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/model"))
    (let ((text (get-output-stream-string output)))
      (check (search "1) alpha" text))
      (check (search "2) beta" text)))))

(deftest slash-model-selects-number-or-valid-id ()
  (let ((session (make-session (make-instance 'test-model-menu-provider :model "alpha"))))
    (dispatch-slash-command session "/model 2")
    (check-equal (provider-model (session-provider session)) "beta")
    (dispatch-slash-command session "/model alpha")
    (check-equal (provider-model (session-provider session)) "alpha")))

(deftest slash-mode-selects-plan-and-direct ()
  (let ((session (make-session (make-instance 'ollama-provider)
                               :tools (list (find-tool "shell") (find-tool "discover-tools")))))
    (check-equal (session-orchestration-mode session) :direct)
    (dispatch-slash-command session "/mode plan")
    (check-equal (session-orchestration-mode session) :plan)
    (setf (session-tools session) (list (find-tool "discover-tools")))
    (dispatch-slash-command session "/mode direct")
    (check-equal (session-orchestration-mode session) :direct)
    (check-equal (mapcar #'tool-name (session-tools session)) '("shell" "discover-tools"))
    (dispatch-slash-command session "/mode plan-review")
    (check-equal (session-orchestration-mode session) :plan-review)))

(deftest slash-session-saves-restores-and-lists-named-snapshots ()
  (with-temp-config-dir ()
    (let* ((session (make-session (make-instance 'ollama-provider :model "saved-model")
                                  :tools (list (find-tool "shell"))))
           (output (make-string-output-stream))
           (arguments (jobj "path" "src/repl.lisp" "line" 1)))
      (setf (session-orchestration-mode session) :plan-review
            (session-max-tool-iterations session) 17
            (session-raw-stats session)
            (list :requests 3 :tool-calls 2 :prompt-tokens 11
                  :completion-tokens 7 :total-tokens 18)
            (session-messages session)
            (list (list :role "system" :content "Saved system instructions.")
                  (list :role "user" :content "Inspect the session feature.")
                  (list :role "assistant" :content nil
                        :tool-calls (list (list :id "call-1" :name "read-file"
                                                :arguments arguments :arguments-error nil))
                        :usage (list :prompt-tokens 4 :completion-tokens 2 :total-tokens 6))
                  (list :role "tool" :tool-call-id "call-1" :content "source text")))
      (let ((*standard-output* output))
        (check (dispatch-slash-command session "/session save demo-session")))
      (check (probe-file (saved-session-path "demo-session")))
      (check (search "Saved session demo-session" (get-output-stream-string output)))
      ;; Damage all restorable state, then prove RESTORE replaces it from the
      ;; JSON snapshot rather than relying on in-memory aliases.
      (setf (session-messages session) (list (list :role "system" :content "different"))
            (session-tools session) nil
            (session-orchestration-mode session) :direct
            (session-max-tool-iterations session) 1
            (session-raw-stats session) (list :requests 0 :tool-calls 0
                                              :prompt-tokens 0 :completion-tokens 0 :total-tokens 0)
            (provider-model (session-provider session)) "different-model")
      (let ((*standard-output* output))
        (check (dispatch-slash-command session "/session restore demo-session")))
      (check-equal (session-orchestration-mode session) :plan-review)
      (check-equal (session-max-tool-iterations session) 17)
      (check-equal (provider-model (session-provider session)) "saved-model")
      (check-equal (getf (session-raw-stats session) :requests) 3)
      (check-equal (mapcar #'tool-name (session-tools session)) '("shell"))
      (check-equal (length (session-messages session)) 4)
      (let* ((call (first (getf (third (session-messages session)) :tool-calls)))
             (restored-arguments (getf call :arguments)))
        (check-equal (getf call :id) "call-1")
        (check-equal (jget restored-arguments "path") "src/repl.lisp")
        (check-equal (jget restored-arguments "line") 1))
      (check (some (lambda (entry) (string= (getf entry :name) "demo-session"))
                   (list-saved-sessions)))
      (let ((*standard-output* output))
        (check (dispatch-slash-command session "/session list")))
      (check (search "demo-session" (get-output-stream-string output))))))

;;; --- stats tracking ---

(deftest session-stats-snapshot-has-live-fields ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (let ((snapshot (session-stats-snapshot session)))
      (check-equal (getf snapshot :provider) (provider-display-name (session-provider session)))
      (check-equal (getf snapshot :requests) 0)
      (check-equal (getf snapshot :tool-calls) 0)
      (check (>= (getf snapshot :elapsed-seconds) 0)))))

(deftest session-note-request-counts-requests-and-sums-usage-when-present ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (session-note-request session (list :role "assistant" :content "hi"
                                         :usage (list :prompt-tokens 10 :completion-tokens 5 :total-tokens 15)))
    (session-note-request session (list :role "assistant" :content "hi" :usage nil))
    (let ((snapshot (session-stats-snapshot session)))
      (check-equal (getf snapshot :requests) 2 "both requests counted, even the one with no usage")
      (check-equal (getf snapshot :prompt-tokens) 10 "only the turn that reported usage contributed")
      (check-equal (getf snapshot :completion-tokens) 5)
      (check-equal (getf snapshot :total-tokens) 15))))

(deftest run-tool-call-increments-tool-call-stat-and-fires-ui-stats-updated ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (stats-updates nil))
    (let ((orig (symbol-function 'ui-stats-updated)))
      (unwind-protect
           (progn
             (setf (symbol-function 'ui-stats-updated) (lambda (f s) (declare (ignore f)) (push s stats-updates)))
             (run-tool-call session (list :id "1" :name "shell"
                                          :arguments (jobj "command" "echo hi"
                                                           "reason" "Verify shell execution."
                                                           "result_use" "Use the output in this test."))))
        (setf (symbol-function 'ui-stats-updated) orig)))
    (check-equal (getf (session-stats-snapshot session) :tool-calls) 1)
    (check stats-updates "UI-STATS-UPDATED fired at least once")))

(deftest run-tool-call-veto-via-before-tool-call-hook-does-not-propagate ()
  ;; Regression test: a :before-tool-call hook signalling an error used
  ;; to propagate all the way out of RUN-TOOL-CALL (and from there,
  ;; RUN-AGENT-TURN) uncaught, contradicting what hooks.lisp's
  ;; *HOOK-POINTS* documents ("signal an error to veto the call
  ;; entirely"). The tool must never run, and the veto's message
  ;; becomes the "tool" role message's content instead.
  (let ((session (make-session (make-instance 'ollama-provider)))
        (shell-ran nil))
    (let ((orig (symbol-function 'call-tool)))
      (unwind-protect
           (progn
             (setf (symbol-function 'call-tool) (lambda (name args) (declare (ignore name args)) (setf shell-ran t) "should not run"))
             (add-hook :before-tool-call 'test-veto (lambda (ctx) (declare (ignore ctx)) (error "nope, not today")))
             (let ((message (run-tool-call session (list :id "1" :name "shell"
                                                         :arguments (jobj "command" "echo hi"
                                                                          "reason" "Exercise the hook."
                                                                          "result_use" "Check whether it permits the call.")))))
               (check (not shell-ran) "the tool itself never ran")
               (check-equal (getf message :role) "tool")
               (check (search "nope, not today" (getf message :content)))))
        (remove-hook :before-tool-call 'test-veto)
        (setf (symbol-function 'call-tool) orig)))))

(deftest run-tool-call-before-tool-call-hook-can-still-mutate-and-allow ()
  ;; The common, non-veto case must still work: a hook that mutates CTX
  ;; and returns normally lets the (mutated) call proceed.
  (let ((session (make-session (make-instance 'ollama-provider))))
    (unwind-protect
         (progn
           (add-hook :before-tool-call 'test-mutate
             (lambda (ctx) (list :tool-name (getf ctx :tool-name) :arguments (jobj "command" "echo mutated"))))
           (let ((message (run-tool-call session (list :id "1" :name "shell"
                                                       :arguments (jobj "command" "echo original"
                                                                        "reason" "Exercise argument rewriting."
                                                                        "result_use" "Confirm the hook's replacement runs.")))))
             (check (search "mutated" (getf message :content)))
             (check (not (search "original" (getf message :content))))))
      (remove-hook :before-tool-call 'test-mutate))))

(deftest run-tool-call-rejects-invalid-model-json-and-alerts-the-model ()
  (let ((called nil)
        (name "json-validation-test"))
    (unwind-protect
         (progn
           (register-tool
            (make-instance 'tool :name name :description "test"
                              :parameters (jobj "type" "object"
                                                "properties" (jobj "count" (jobj "type" "integer"))
                                                "required" (list "count"))
                              :handler (lambda (arguments)
                                         (declare (ignore arguments))
                                         (setf called t)
                                         "should not run")))
           (let* ((session (make-session (make-instance 'ollama-provider)))
                  (result (run-tool-call session
                                         (list :id "bad-json" :name name
                                               :arguments (jobj "count" "not an integer")))))
             (check (not called))
             (check (search "JSON arguments are invalid" (getf result :content)))
             (check (search "arguments.count must be a JSON integer" (getf result :content)))))
      (unregister-tool name))))

(deftest run-tool-call-returns-unknown-tool-feedback-and-keeps-the-turn-alive ()
  ;; Exercise the actual agent dispatch path: a hallucinated tool name used
  ;; to signal TOOL-NOT-FOUND out of RUN-TOOL-CALL and abort the turn.
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (result (run-tool-call session
                                (list :id "unknown-tool" :name "readme"
                                      :arguments (jobj)))))
    (check-equal (getf result :role) "tool")
    (check-equal (getf result :tool-call-id) "unknown-tool")
    (check (search "readme" (getf result :content)))
    (check (search "does not exist" (getf result :content)))))

(deftest shell-command-inspector-rejects-with-model-feedback ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (complete (symbol-function 'session-complete))
         (called nil))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Explain a library"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   "{\"decision\":\"reject\",\"reason\":\"The search scope is not justified\",\"alternative\":\"Inspect the known project directory\",\"rewritten_command\":\"rg -n \\\"library\\\" src\"}"))
           (let ((original (symbol-function 'call-tool)))
             (unwind-protect
                  (progn
                    (setf (symbol-function 'call-tool)
                          (lambda (&rest ignored) (declare (ignore ignored)) (setf called t) "ran"))
                    (let ((*current-session* session))
                      (let ((result (run-tool-call session (list :id "inspect" :name "shell"
                                                                  :arguments (jobj "command" "some command"
                                                                                   "reason" "Obtain focused evidence."
                                                                                   "result_use" "Use it to answer the library question.")))))
                        (check (not called))
                        (check (search "Shell command was not run" (getf result :content)))
                        (check (search "rg -n \"library\" src" (getf result :content))))))
               (setf (symbol-function 'call-tool) original))))
      (setf (symbol-function 'session-complete) complete))))

(deftest shell-command-inspector-accepts-json-wrapped-in-prose-or-a-fence ()
  (dolist (response (list "Decision follows:\n```json\n{\"decision\":\"allow\",\"reason\":\"bounded source read\",\"alternative\":null}\n```"
                          "I approve it. {\"decision\":\"reject\",\"reason\":\"too broad\",\"alternative\":\"Read one file\"}"))
    (let ((inspection (parse-shell-command-inspection response)))
      (check (getf inspection :valid-p))
      (check (member (getf inspection :decision) '(:allow :reject))))))

(deftest shell-command-inspector-retries-one-malformed-review ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (complete (symbol-function 'session-complete))
         (original-call-tool (symbol-function 'call-tool))
         (reviews 0)
         (called nil))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Read this project file."))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   (incf reviews)
                   (if (= reviews 1)
                       "I would allow this command."
                       "{\"decision\":\"allow\",\"reason\":\"the target is bounded\",\"alternative\":null}")))
           (setf (symbol-function 'call-tool)
                 (lambda (&rest ignored) (declare (ignore ignored)) (setf called t) "ran"))
           (let ((*current-session* session))
             (run-tool-call session
                            (list :id "format-retry" :name "shell"
                                  :arguments (jobj "command" "sed -n '1,40p' src/repl.lisp"
                                                   "reason" "Read the targeted implementation."
                                                   "result_use" "Use it to explain the behavior."))))
           (check called)
           (check-equal reviews 2))
      (setf (symbol-function 'session-complete) complete
            (symbol-function 'call-tool) original-call-tool))))

(deftest shell-command-inspector-receives-goal-rationale-and-intended-result-use ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (complete (symbol-function 'session-complete))
         (original-call-tool (symbol-function 'call-tool))
         (review-prompt nil)
         (called nil))
    (setf (session-messages session)
          (append (session-messages session)
                  (list (list :role "user" :content "Show me an interesting piece of code in this repository."))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (prompt &key system model)
                   (declare (ignore system model))
                   (setf review-prompt prompt)
                   "{\"decision\":\"allow\",\"reason\":\"The source directory is bounded\",\"alternative\":null}"))
           (setf (symbol-function 'call-tool)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   (setf called t)
                   "src/repl.lisp"))
           (let ((*current-session* session))
             (run-tool-call
              session
              (list :id "contextual-inspect" :name "shell"
                    :arguments (jobj "command" "ls src/"
                                     "reason" "Identify candidate source files before choosing a useful code example."
                                     "result_use" "Read a candidate file and select a snippet to show the user."))))
           (check called "accepted command runs")
           (check (search "Show me an interesting piece of code" review-prompt)
                  "goal is sent to the inspector")
           (check (search "Identify candidate source files" review-prompt) "rationale is sent to the inspector")
           (check (search "Read a candidate file and select a snippet" review-prompt) "intended result use is sent to the inspector")
           (check (search "ls src/" review-prompt) "command is sent to the inspector"))
      (setf (symbol-function 'session-complete) complete
            (symbol-function 'call-tool) original-call-tool))))

(deftest shell-command-inspector-asks-for-a-rewrite-grounded-in-intent ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (complete (symbol-function 'session-complete))
         (review-system nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (prompt &key system model)
                   (declare (ignore prompt model))
                   (setf review-system system)
                   "{\"decision\":\"reject\",\"reason\":\"too broad\",\"alternative\":\"read the target file\",\"rewritten_command\":\"sed -n '1,80p' src/repl.lisp\"}"))
           (let ((*current-session* session))
             (let ((inspection (inspect-shell-command
                                session "rg shell ."
                                "Find the shell inspector implementation."
                                "Read it before changing its review response.")))
               (check-equal (getf inspection :rewritten-command)
                            "sed -n '1,80p' src/repl.lisp")
               (check (search "stated reason and intended result use" review-system))
               (check (search "never executed automatically" review-system)))))
      (setf (symbol-function 'session-complete) complete))))

(deftest shell-command-inspector-rejects-whole-host-discovery-before-model-review ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (complete (symbol-function 'session-complete))
         (called nil))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Explain an installed library"))))
    (unwind-protect
         (progn
           ;; The structural inspector must reject this before asking a model
           ;; that might otherwise endorse its own over-broad suggestion.
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored) (declare (ignore ignored))
                   (error "model review should not run")))
           (let ((original (symbol-function 'call-tool)))
             (unwind-protect
                  (progn
                    (setf (symbol-function 'call-tool)
                          (lambda (&rest ignored) (declare (ignore ignored)) (setf called t) "ran"))
                    (let ((*current-session* session))
                      (let ((result (run-tool-call session (list :id "whole-host" :name "shell"
                                                                  :arguments (jobj "command" "find / -name '*.lisp'"
                                                                                   "reason" "Locate the library."
                                                                                   "result_use" "Read the discovered file.")))))
                        (check (not called))
                        (check (search "entire host filesystem" (getf result :content))))))
               (setf (symbol-function 'call-tool) original))))
      (setf (symbol-function 'session-complete) complete))))

;;; --- SESSION-COMPLETE / *CURRENT-SESSION* ---

(deftest session-complete-signals-without-a-running-session ()
  (let ((*current-session* nil))
    (check-condition error (session-complete "hello"))))

(deftest session-complete-uses-current-sessions-provider-and-counts-stats ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (seen-messages nil)
        (orig (symbol-function 'chat)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat)
                 (lambda (provider messages tools)
                   (declare (ignore provider tools))
                   (setf seen-messages messages)
                   (list :role "assistant" :content "a Seussian reply"
                         :usage (list :prompt-tokens 3 :completion-tokens 4 :total-tokens 7))))
           (let ((*current-session* session))
             (check-equal (session-complete "rewrite this" :system "be seussian") "a Seussian reply")))
      (setf (symbol-function 'chat) orig))
    (check-equal (getf (first seen-messages) :role) "system")
    (check-equal (getf (first seen-messages) :content) "be seussian")
    (check-equal (getf (second seen-messages) :content) "rewrite this")
    (check-equal (getf (session-stats-snapshot session) :requests) 1 "SESSION-COMPLETE counts as a real request")
    (check-equal (getf (session-stats-snapshot session) :total-tokens) 7)
    (check-equal (length (session-messages session)) 1 "SESSION-COMPLETE does not touch the visible conversation (still just the initial system message)")))

(deftest session-complete-model-does-not-change-main-session-model ()
  (let* ((session (make-session (make-provider :ollama :model "main-model")))
         (seen-model nil)
         (orig (symbol-function 'chat)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat)
                 (lambda (provider messages tools)
                   (declare (ignore messages tools))
                   (setf seen-model (provider-model provider))
                   (list :role "assistant" :content "independent" :tool-calls nil)))
           (let ((*current-session* session))
             (check-equal (session-complete "question" :model "other-model") "independent")))
      (setf (symbol-function 'chat) orig))
    (check-equal seen-model "other-model")
    (check-equal (provider-model (session-provider session)) "main-model")))

(deftest run-agent-turn-binds-current-session-for-hooks-and-tools ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (seen nil)
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (setf seen *current-session*)
                   (list :role "assistant" :content "done" :tool-calls nil :usage nil)))
           (run-agent-turn session))
      (setf (symbol-function 'chat-stream) orig))
    (check-equal seen session)))

(deftest run-agent-turn-does-not-revise-user-lisp-for-missing-type-claims ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (calls 0)
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider tools on-delta))
                   (incf calls)
                   (list :role "assistant"
                         :content (format nil "```lisp~%(in-package :cl-agent)~%(defun generated-untyped (x) x)~%```~%")
                         :tool-calls nil :usage nil)))
           ;; Lisp presentation normalization uppercases symbols, so verify
           ;; the generated name without depending on its printed case.
           (check (search "generated-untyped" (getf (run-agent-turn session) :content)
                          :test #'char-equal)))
      (setf (symbol-function 'chat-stream) orig))
    (check-equal calls 1 "missing type claims stay advisory for user code")))

(deftest run-agent-turn-preserves-a-draft-during-automatic-lisp-revision ()
  (let* ((frontend (make-instance 'recording-frontend))
         (session (make-session (make-instance 'ollama-provider) :frontend frontend))
         (stream (symbol-function 'chat-stream))
         (review (symbol-function 'review-assistant-common-lisp))
         (calls 0))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (incf calls)
                   (list :role "assistant" :content (if (= calls 1) "draft proposal" "revised proposal")
                         :tool-calls nil :usage nil)))
           (setf (symbol-function 'review-assistant-common-lisp)
                 (lambda (content)
                   (if (string= content "draft proposal")
                       (list (list :compile-failure-p t))
                       nil)))
           (check-equal (getf (run-agent-turn session) :content) "revised proposal"))
      (setf (symbol-function 'chat-stream) stream
            (symbol-function 'review-assistant-common-lisp) review))
    (let ((texts (mapcar #'second
                         (remove-if-not (lambda (event) (and (consp event) (eq (first event) :text)))
                                        (recording-frontend-events frontend)))))
      (check (member "draft proposal" texts :test #'string=)
             "the first streamed proposal remains visible while it is revised")
      (check (member "revised proposal" texts :test #'string=)))))

(deftest plan-review-accepts-a-verified-final-answer ()
  (let* ((session (make-session (make-instance 'ollama-provider) :orchestration-mode :plan-review))
         (stream (symbol-function 'chat-stream))
         (complete (symbol-function 'session-complete)))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Original request: verify it"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (list :role "assistant" :content "Verified answer" :tool-calls nil :usage nil)))
           (setf (symbol-function 'session-complete)
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   "{\"decision\":\"accept\",\"reason\":\"Evidence is sufficient\",\"missing_verification\":[]}"))
           (check-equal (getf (run-agent-turn session) :content) "Verified answer"))
      (setf (symbol-function 'chat-stream) stream
            (symbol-function 'session-complete) complete))))

(deftest plan-review-requests-one-revision-then-accepts ()
  (let* ((session (make-session (make-instance 'ollama-provider) :orchestration-mode :plan-review))
         (stream (symbol-function 'chat-stream))
         (complete (symbol-function 'session-complete))
         (model-calls 0)
         (review-calls 0)
         (output (make-string-output-stream)))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Original request: verify it"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (incf model-calls)
                   (list :role "assistant" :content (if (= model-calls 1) "draft" "revised")
                         :tool-calls nil :usage nil)))
           (setf (symbol-function 'session-complete)
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   (incf review-calls)
                   (if (= review-calls 1)
                       "{\"decision\":\"revise\",\"reason\":\"Run the test\",\"missing_verification\":[\"test output\"]}"
                       "{\"decision\":\"accept\",\"reason\":\"Test output is present\",\"missing_verification\":[]}")))
           (let ((*standard-output* output))
             (check-equal (getf (run-agent-turn session) :content) "revised")))
      (setf (symbol-function 'chat-stream) stream
            (symbol-function 'session-complete) complete))
    (check-equal model-calls 2)
    (check-equal review-calls 2)
    (let ((text (get-output-stream-string output)))
      (check (not (search "draft" text)) "unreviewed draft is not shown")
      (check (search "revised" text)))))

(deftest malformed-completion-review-blocks ()
  (let ((review (parse-completion-review "not JSON")))
    (check-equal (getf review :decision) :block)
    (check (search "unusable" (getf review :reason)))))

(deftest plan-review-hides-a-blocked-final-answer ()
  (let* ((session (make-session (make-instance 'ollama-provider) :orchestration-mode :plan-review))
         (stream (symbol-function 'chat-stream))
         (complete (symbol-function 'session-complete))
         (output (make-string-output-stream)))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content "Original request: verify it"))))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (list :role "assistant" :content "unsupported claim" :tool-calls nil :usage nil)))
           (setf (symbol-function 'session-complete)
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   "{\"decision\":\"block\",\"reason\":\"No test evidence\",\"missing_verification\":[\"test output\"]}"))
           (let ((*standard-output* output))
             (check-equal (getf (run-agent-turn session) :content) "unsupported claim")))
      (setf (symbol-function 'chat-stream) stream
            (symbol-function 'session-complete) complete))
    (let ((text (get-output-stream-string output)))
      (check (search "[review] BLOCK" text))
      (check (not (search "unsupported claim" text))))))

;;; --- SESSION-SUBMIT-USER-TEXT / :USER-MESSAGE ---

(deftest session-submit-user-text-with-no-hooks-appends-as-is ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (session-submit-user-text session "hello there")
    (check-equal (getf (first (last (session-messages session))) :role) "user")
    (check-equal (getf (first (last (session-messages session))) :content) "hello there")))

(deftest session-submit-user-text-creates-a-durable-task-record ()
  (with-temp-config-dir ()
    (let ((session (make-session (make-instance 'ollama-provider))))
      (session-submit-user-text session "record this task")
      (let ((record (session-task-record session)))
        (check-equal (jget record "status") "executing")
        (check-equal (jget record "original_request") "record this task")
        (check (probe-file (merge-pathnames (format nil "~a.json" (jget record "id"))
                                            (task-record-directory))))))))

(deftest plan-mode-shows-and-submits-a-validated-execution-brief ()
  (let* ((session (make-session (make-instance 'ollama-provider)
                                :tools (list (find-tool "shell"))
                                :orchestration-mode :plan))
         (output (make-string-output-stream))
         (original (symbol-function 'session-complete)))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (prompt &key system model)
                   (declare (ignore prompt system model))
                   "{\"rewritten_prompt\":\"Inspect the source tree\",\"plan\":[\"List files\",\"Read relevant code\"],\"suggested_tools\":[\"shell\",\"not-a-tool\"],\"verification\":[\"Confirm the target files were read\"]}"))
           (let ((*current-session* session) (*standard-output* output))
             (session-submit-user-text session "look through the project")))
      (setf (symbol-function 'session-complete) original))
    (let ((visible (get-output-stream-string output))
          (submitted (getf (first (last (session-messages session))) :content)))
      (check (search "[plan]" visible))
      (check (search "Inspect the source tree" submitted))
      (check (search "shell" submitted))
      (check (not (search "not-a-tool" submitted)))
      (check (search "look through the project" submitted)))))

(deftest malformed-planning-output-keeps-the-original-request ()
  (let* ((session (make-session (make-instance 'ollama-provider) :orchestration-mode :plan))
         (original (symbol-function 'session-complete)))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest arguments) (declare (ignore arguments)) "not json"))
           (let ((*current-session* session))
             (session-submit-user-text session "do the thing")))
      (setf (symbol-function 'session-complete) original))
    (check (search "Original request: do the thing"
                   (getf (first (last (session-messages session))) :content)))))

(deftest fenced-planning-json-is-accepted-without-relaxing-the-schema ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (brief (parse-planning-brief
                 "```json\n{\"rewritten_prompt\":\"Inspect the project\",\"plan\":[\"Read README\"],\"suggested_tools\":[\"shell\"],\"verification\":[\"Cite the README\"]}\n```"
                 "inspect it" session)))
    (check (getf brief :valid-p))
    (check-equal (getf brief :rewritten-prompt) "Inspect the project")))

(deftest subagent-delegation-plan-is-structured-and-does-not-start-workers ()
  (let ((brief (parse-subagent-delegation-brief
                "{\"needed\":true,\"tasks\":[{\"role\":\"explorer\",\"task\":\"Map source files\",\"system_prompt\":\"Inspect bounded project files.\"}]}")))
    (check (getf brief :needed-p))
    (check-equal (getf (first (getf brief :tasks)) :role) "explorer")
    (check (search "not started" (format-subagent-delegation-brief brief)))))

(deftest plan-mode-curates-to-planned-tools-and-discovery ()
  (let* ((shell (find-tool "shell"))
         (discover (find-tool "discover-tools"))
         (review (find-tool "review-lisp"))
         (session (make-session (make-instance 'ollama-provider)
                                :tools (list shell discover review)
                                :orchestration-mode :plan))
         (brief (list :valid-p t :suggested-tools (list "shell"))))
    (activate-planned-tools session brief)
    (check-equal (mapcar #'tool-name (session-tools session)) '("shell" "discover-tools"))
    (let ((*current-session* session))
      (call-tool "discover-tools" (jobj "query" "review")))
    (check (member "review-lisp" (mapcar #'tool-name (session-tools session)) :test #'string=)
           "discovery enables matching catalog tools for the next request")))

(deftest invalid-plan-output-preserves-the-full-tool-set ()
  (let* ((shell (find-tool "shell"))
         (discover (find-tool "discover-tools"))
         (session (make-session (make-instance 'ollama-provider) :tools (list shell discover)
                                :orchestration-mode :plan)))
    (setf (session-tools session) nil)
    (activate-planned-tools session (list :valid-p nil))
    (check-equal (mapcar #'tool-name (session-tools session)) '("shell" "discover-tools"))))

(deftest session-submit-user-text-hook-can-rewrite-the-text ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (unwind-protect
         (progn
           (add-hook :user-message 'test-formalize
             (lambda (ctx) (list :text (format nil "FORMAL: ~a" (getf ctx :text)))))
           (session-submit-user-text session "yo what's up")
           (check-equal (getf (first (last (session-messages session))) :content) "FORMAL: yo what's up"))
      (remove-hook :user-message 'test-formalize))))

(deftest session-submit-user-text-hook-can-expand-the-text-with-a-plan ()
  ;; The "user plan" use case: a hook prepends synthesized reasoning
  ;; (here, a stand-in for a real SESSION-COMPLETE-driven plan) ahead
  ;; of the original text, rather than replacing it outright.
  (let ((session (make-session (make-instance 'ollama-provider))))
    (unwind-protect
         (progn
           (add-hook :user-message 'test-plan
             (lambda (ctx) (list :text (format nil "[plan: use the shell tool]~%~a" (getf ctx :text)))))
           (session-submit-user-text session "what files are here")
           (let ((content (getf (first (last (session-messages session))) :content)))
             (check (search "[plan:" content))
             (check (search "what files are here" content))))
      (remove-hook :user-message 'test-plan))))

(deftest session-submit-user-text-hook-sees-current-session ()
  ;; A :USER-MESSAGE hook fires from RUN-REPL, outside RUN-AGENT-TURN's
  ;; own narrower *CURRENT-SESSION* binding -- SESSION-SUBMIT-USER-TEXT
  ;; must work (i.e. SESSION-COMPLETE must be callable) even when called
  ;; on its own, not just from inside RUN-REPL's broader binding.
  (let ((session (make-session (make-instance 'ollama-provider)))
        (seen :unset))
    (unwind-protect
         (progn
           (add-hook :user-message 'test-sees-session
             (lambda (ctx) (setf seen *current-session*) ctx))
           (let ((*current-session* session))
             (session-submit-user-text session "hi")))
      (remove-hook :user-message 'test-sees-session))
    (check-equal seen session)))

(deftest run-repl-binds-current-session-for-the-whole-session ()
  ;; Stubs CHAT-STREAM (not the network) since this exercises RUN-REPL
  ;; itself, which (via the initial task) reaches RUN-AGENT-TURN for
  ;; real -- same DI pattern as RUN-AGENT-TURN-STREAMS-THROUGH-THE-
  ;; RECORDING-FRONTEND above.
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (seen :unset)
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (list :role "assistant" :content "done" :tool-calls nil :usage nil)))
           (add-hook :user-message 'test-run-repl-sees-session
             (lambda (ctx) (setf seen *current-session*) ctx))
           (with-input-from-string (*standard-input* "")
             (run-repl session :initial-task "hi")))
      (remove-hook :user-message 'test-run-repl-sees-session)
      (setf (symbol-function 'chat-stream) orig))
    (check-equal seen session)))

(deftest slash-stats-shows-formatted-snapshot ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/stats"))
    (let ((text (get-output-stream-string output)))
      (check (search "request" text))
      (check (search (provider-display-name (session-provider session)) text)))))

(deftest slash-doctor-renders-local-diagnostic-report ()
  (with-temp-config-dir ()
    (let ((session (make-session (make-instance 'ollama-provider)))
          (output (make-string-output-stream)))
      (let ((*standard-output* output))
        (check (dispatch-slash-command session "/doctor")))
      (check (search "cl-agent doctor:" (get-output-stream-string output))))))

(deftest slash-context-shows-next-request-context-diagram ()
  (let* ((session (make-session (make-instance 'ollama-provider)
                                :tools (list (find-tool "shell"))))
         (output (make-string-output-stream)))
    (setf (session-messages session)
          (append (session-messages session)
                  (list (list :role "user" :content "Inspect this repository."))))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/context"))
    (let ((text (get-output-stream-string output)))
      (check (search "Context for the next model request" text))
      (check (search "conversation:" text))
      (check (search "tool schemas:" text))
      (check (search "not advertised" text)))))

(deftest slash-compact-replaces-history-only-on-user-command ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (output (make-string-output-stream))
         (complete (symbol-function 'session-complete))
         (initial-system (first (session-messages session))))
    (setf (session-messages session)
          (append (session-messages session)
                  (list (list :role "user" :content "Change the command inspector.")
                        (list :role "assistant" :content "I will add context."))))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   "Goal: improve command inspection. Changed: add rationale context. Next: test it."))
           (let ((*current-session* session) (*standard-output* output))
             (dispatch-slash-command session "/compact"))
           (check-equal (length (session-messages session)) 2)
           (check-equal (first (session-messages session)) initial-system)
           (check (search "User-requested context compaction"
                          (getf (second (session-messages session)) :content)))
           (check (search "Context compacted on request" (get-output-stream-string output))))
      (setf (symbol-function 'session-complete) complete))))

(deftest run-subagent-isolated-and-reports-to-its-parent ()
  (let* ((parent (make-session (make-instance 'ollama-provider)))
         (original (symbol-function 'run-agent-turn))
         (child nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'run-agent-turn)
                 (lambda (session)
                   (setf child session)
                   (list :role "assistant" :content "Found the relevant source file.")))
           (let ((report (run-subagent parent "Locate the entry point." "Be a focused explorer."
                                       (list (find-tool "shell")))))
             (check (search "Found the relevant source file" report))
             (check-equal (session-subagent-depth child) 1)
             (check-equal (session-max-tool-iterations child) 1000)
             (check-equal (mapcar #'tool-name (session-tools child)) '("shell"))
             (check-equal (length (session-messages parent)) 1)))
      (setf (symbol-function 'run-agent-turn) original))))

(deftest compact-subagent-model-profiles-route-and-guide-workers ()
  (let* ((parent (make-session
                  (make-instance 'ollama-provider :model "host-model")
                  :subagent-model-profiles
                  '((:tool "fast-model" :description "quick inspection"
                            :max-tool-iterations 3 :system-prompt "Be terse.")
                    (:deep-research "glm-5.2" :description "hard analysis"))))
         (original (symbol-function 'run-agent-turn))
         (child nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'run-agent-turn)
                 (lambda (session)
                   (setf child session)
                   (list :role "assistant" :content "worker report")))
           (check (search "deep-research → glm-5.2"
                          (getf (first (session-messages parent)) :content)))
           (check (search "worker report"
                          (run-subagent parent "inspect" "Inspect carefully." nil
                                        :profile "tool")))
           (check-equal (provider-model (session-provider child)) "fast-model")
           (check-equal (session-max-tool-iterations child) 3)
           (check (search "Profile guidance:" (getf (first (session-messages child)) :content)))
           (check-equal (getf (find-subagent-model-profile parent :deep-research) :model)
                        "glm-5.2"))
      (setf (symbol-function 'run-agent-turn) original))))

(deftest unknown-subagent-model-profile-does-not-fall-back-silently ()
  (let ((parent (make-session (make-instance 'ollama-provider)
                              :subagent-model-profiles '((:tool "fast-model")))))
    (check (search "unknown model profile"
                   (run-subagent parent "inspect" "Inspect." nil :profile "typo")))))

(deftest run-subagent-respects-configured-depth-limit ()
  (let ((parent (make-session (make-instance 'ollama-provider)
                              :subagent-depth 1 :max-subagent-depth 1)))
    (check (search "not started" (run-subagent parent "task" "system" nil)))))

;;; --- RUN-AGENT-TURN uses CHAT-STREAM and fires the UI hooks ---

(defclass recording-frontend (agent-frontend)
  ((events :initform nil :accessor recording-frontend-events)))
(defmethod ui-thinking-started ((f recording-frontend)) (push :thinking-started (recording-frontend-events f)))
(defmethod ui-thinking-stopped ((f recording-frontend)) (push :thinking-stopped (recording-frontend-events f)))
(defmethod ui-assistant-delta ((f recording-frontend) chunk) (push (list :delta chunk) (recording-frontend-events f)))
(defmethod ui-assistant-text ((f recording-frontend) text) (push (list :text text) (recording-frontend-events f)))
(defmethod ui-stats-updated ((f recording-frontend) stats) (declare (ignore stats)) (push :stats (recording-frontend-events f)))

(deftest run-agent-turn-streams-through-the-recording-frontend ()
  ;; Stubs CHAT-STREAM itself (not the network) so this is a pure unit
  ;; test of RUN-AGENT-TURN's wiring: does it actually call CHAT-STREAM
  ;; (not the non-streaming CHAT) and fire the UI hooks in order?
  (let* ((frontend (make-instance 'recording-frontend))
         (session (make-session (make-instance 'ollama-provider) :frontend frontend))
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools))
                   (funcall on-delta "hel")
                   (funcall on-delta "lo")
                   (list :role "assistant" :content "hello" :tool-calls nil :usage nil)))
           (run-agent-turn session))
      (setf (symbol-function 'chat-stream) orig))
    (let ((events (nreverse (recording-frontend-events frontend))))
      (check-equal events '(:thinking-started (:delta "hel") (:delta "lo") (:text "hello") :stats :thinking-stopped)))))

(deftest run-agent-turn-keeps-one-activity-interval-across-follow-up-requests ()
  "A revision retry represents the same multi-request lifecycle as a tool
round: the UI must not flicker between individual provider calls."
  (let* ((frontend (make-instance 'recording-frontend))
         (session (make-session (make-instance 'ollama-provider) :frontend frontend))
         (calls 0)
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages tools on-delta))
                   (incf calls)
                   (if (= calls 1)
                       (list :role "assistant"
                             :content (format nil "```lisp~%(in-package :cl-agent)~%(defun needs-review (x) x)~%```")
                             :tool-calls nil :usage nil)
                       (list :role "assistant" :content "revised" :tool-calls nil :usage nil))))
           (run-agent-turn session))
      (setf (symbol-function 'chat-stream) orig))
    (let ((events (nreverse (recording-frontend-events frontend))))
      (check-equal (count :thinking-started events) 1)
      (check-equal (count :thinking-stopped events) 1)
      (check-equal (first events) :thinking-started)
      (check-equal (car (last events)) :thinking-stopped))))

(deftest tool-budget-denial-forces-a-final-no-tool-response ()
  (define-tool test-tool-budget-probe (args)
    (:description "Test-only tool for the budget reviewer." :parameters (jobj "type" "object"))
    (format nil "should not run: ~s" args))
  (let* ((session (make-session (make-instance 'ollama-provider)
                                :tools (list (find-tool "test-tool-budget-probe"))
                                :max-tool-iterations 1))
         (calls 0)
         (stream (symbol-function 'chat-stream))
         (complete (symbol-function 'session-complete)))
    (unwind-protect
         (progn
           (setf (symbol-function 'session-complete)
                 (lambda (&rest ignored)
                   (declare (ignore ignored))
                   "{\"decision\":\"finish\",\"reason\":\"Further probing would be speculative\",\"extra_rounds\":0}"))
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider messages on-delta))
                   (incf calls)
                   (if (= calls 1)
                       (list :role "assistant" :content nil :usage nil
                             :tool-calls (list (list :id "budget-call" :name "test-tool-budget-probe"
                                                     :arguments (make-hash-table))))
                       (progn
                         (check-equal tools nil "the finalizing request must not expose tools")
                         (list :role "assistant" :content "Here is the best answer from the evidence." :tool-calls nil :usage nil)))))
           (check-equal (getf (run-agent-turn session) :content) "Here is the best answer from the evidence."))
      (setf (symbol-function 'chat-stream) stream
            (symbol-function 'session-complete) complete)
      (unregister-tool "test-tool-budget-probe"))
    (check-equal calls 2)))

(deftest plan-budget-review-can-approve-a-large-completion-extension ()
  (let ((review (parse-tool-budget-review
                 "{\"decision\":\"extend\",\"reason\":\"Two concrete verification steps remain\",\"extra_rounds\":1000}"
                 1000)))
    (check-equal (getf review :decision) :extend)
    (check-equal (getf review :extra-rounds) 1000))
  (let ((session (make-session (make-instance 'ollama-provider)
                               :orchestration-mode :plan)))
    (check (completion-oriented-budget-p session))))
