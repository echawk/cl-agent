;;;; t/test-settings.lisp -- Setinka settings on live session mechanics.

(in-package :cl-agent)

(deftest durable-settings-are-validated-persisted-and-reloaded ()
  (with-temp-config-dir ()
    (let ((settings (load-agent-settings)))
      (check-equal (setinka:config :compaction-percent settings) 80)
      (setf (setinka:config :compaction-percent settings) "65")
      (setf (setinka:config :orchestration-mode settings) "plan")
      (setf (setinka:config :shell-default-expected-seconds settings) "21")
      (setf (setinka:config :sandbox-network-mode settings) "enabled")
      (check-equal (setinka:config :compaction-percent settings) 65)
      (check-equal (setinka:config :orchestration-mode settings) :plan)
      (check-equal (setinka:config :shell-default-expected-seconds settings) 21)
      (check-equal (setinka:config :sandbox-network-mode settings) :enabled)
      (check-condition setinka:setting-invalid
        (setf (setinka:config :max-subagent-depth settings) "-1")))
    (let ((reloaded (load-agent-settings)))
      (check-equal (setinka:config :compaction-percent reloaded) 65)
      (check-equal (setinka:config :orchestration-mode reloaded) :plan)
      (check-equal (setinka:config :shell-default-expected-seconds reloaded) 21)
      (check-equal (setinka:config :sandbox-network-mode reloaded) :enabled))))

(deftest session-settings-update-live-agent-mechanics ()
  (with-temp-config-dir ()
    (let* ((settings (load-agent-settings))
           (session (make-session (make-instance 'ollama-provider) :settings settings)))
      (setf (setinka:config :compaction-percent settings) 25
            (setinka:config :max-tool-iterations settings) 12
            (setinka:config :orchestration-mode settings) :plan
            (setinka:config :max-subagent-depth settings) 2
            (setinka:config :subagent-concurrency settings) 2)
      (check-equal (session-context-compaction-threshold session) 0.25)
      (check-equal (session-max-tool-iterations session) 12)
      (check-equal (session-orchestration-mode session) :plan)
      (check-equal (session-max-subagent-depth session) 2)
      (check-equal *subagent-max-concurrency* 2)
      (check (search "compaction-percent: 25" (format-session-settings session))))))

(deftest typed-tool-settings-drive-shell-and-sandbox-policy-defaults ()
  (with-temp-config-dir ()
    (let* ((settings (load-agent-settings))
           (session (make-session (make-instance 'ollama-provider) :settings settings)))
      (setf (setinka:config :shell-default-expected-seconds settings) 17
            (setinka:config :shell-maximum-seconds settings) 23
            (setinka:config :sandbox-network-mode settings) :enabled)
      (let ((*current-session* session))
        (check-equal (current-agent-setting :shell-default-expected-seconds 10) 17)
        (check-equal (shell-warning-delay 99 nil) 23)
        (check-equal (cl-exec-sandbox:sandbox-policy-network (make-agent-sandbox-policy)) :enabled)))))

(deftest slash-settings-reflects-and-updates-the-current-session ()
  (with-temp-config-dir ()
    (let ((session (make-session (make-instance 'ollama-provider)))
          (output (make-string-output-stream)))
      (let ((*standard-output* output))
        (dispatch-slash-command session "/settings set compaction_percent 30")
        (dispatch-slash-command session "/settings get compaction-percent"))
      (check-equal (session-context-compaction-threshold session) 0.3)
      (check (search "compaction-percent: 30" (get-output-stream-string output))))))
