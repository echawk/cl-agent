(in-package :cl-agent)

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

(deftest slash-call-unknown-tool-reports-error-not-condition ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (check (dispatch-slash-command session "/call no-such-tool-xyz {}")))
    (check (search "[error]" (get-output-stream-string output)))))

(deftest slash-tools-lists-session-tools ()
  (let* ((session (make-session (make-instance 'ollama-provider) :tools (list (find-tool "shell"))))
         (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/tools"))
    (check (search "shell" (get-output-stream-string output)))))

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
             (run-tool-call session (list :id "1" :name "shell" :arguments (jobj "command" "echo hi"))))
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
             (let ((message (run-tool-call session (list :id "1" :name "shell" :arguments (jobj "command" "echo hi")))))
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
           (let ((message (run-tool-call session (list :id "1" :name "shell" :arguments (jobj "command" "echo original")))))
             (check (search "mutated" (getf message :content)))
             (check (not (search "original" (getf message :content))))))
      (remove-hook :before-tool-call 'test-mutate))))

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

(deftest run-agent-turn-requests-one-revision-for-unreviewed-lisp ()
  (let* ((session (make-session (make-instance 'ollama-provider)))
         (calls 0)
         (orig (symbol-function 'chat-stream)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat-stream)
                 (lambda (provider messages tools on-delta)
                   (declare (ignore provider tools on-delta))
                   (incf calls)
                   (if (= calls 1)
                       (list :role "assistant"
                             :content (format nil "```lisp~%(in-package :cl-agent)~%(defun generated-untyped (x) x)~%```~%")
                             :tool-calls nil :usage nil)
                       (progn
                         (check (search "Automatic review of generated Common Lisp"
                                        (getf (first (last messages)) :content)))
                         (list :role "assistant" :content "revised" :tool-calls nil :usage nil)))))
           (check-equal (getf (run-agent-turn session) :content) "revised"))
      (setf (symbol-function 'chat-stream) orig))
    (check-equal calls 2 "one automatic feedback round was requested")))

;;; --- SESSION-SUBMIT-USER-TEXT / :USER-MESSAGE ---

(deftest session-submit-user-text-with-no-hooks-appends-as-is ()
  (let ((session (make-session (make-instance 'ollama-provider))))
    (session-submit-user-text session "hello there")
    (check-equal (getf (first (last (session-messages session))) :role) "user")
    (check-equal (getf (first (last (session-messages session))) :content) "hello there")))

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
      (check-equal events '(:thinking-started (:delta "hel") (:delta "lo") :thinking-stopped (:text "hello") :stats)))))
