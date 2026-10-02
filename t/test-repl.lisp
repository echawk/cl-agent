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
