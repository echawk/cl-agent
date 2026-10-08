;;;; t/test-settings.lisp -- Setinka settings on live session mechanics.

(in-package :cl-agent)

(deftest durable-settings-are-validated-persisted-and-reloaded ()
  (with-temp-config-dir ()
    (let ((settings (load-agent-settings)))
      (check-equal (setinka:config :compaction-percent settings) 80)
      (setf (setinka:config :compaction-percent settings) "65")
      (setf (setinka:config :orchestration-mode settings) "plan")
      (check-equal (setinka:config :compaction-percent settings) 65)
      (check-equal (setinka:config :orchestration-mode settings) :plan)
      (check-condition setinka:setting-invalid
        (setf (setinka:config :max-subagent-depth settings) "-1")))
    (let ((reloaded (load-agent-settings)))
      (check-equal (setinka:config :compaction-percent reloaded) 65)
      (check-equal (setinka:config :orchestration-mode reloaded) :plan))))

(deftest session-settings-update-live-agent-mechanics ()
  (with-temp-config-dir ()
    (let* ((settings (load-agent-settings))
           (session (make-session (make-instance 'ollama-provider) :settings settings)))
      (setf (setinka:config :compaction-percent settings) 25
            (setinka:config :max-tool-iterations settings) 12
            (setinka:config :orchestration-mode settings) :plan
            (setinka:config :max-subagent-depth settings) 2)
      (check-equal (session-context-compaction-threshold session) 0.25)
      (check-equal (session-max-tool-iterations session) 12)
      (check-equal (session-orchestration-mode session) :plan)
      (check-equal (session-max-subagent-depth session) 2)
      (check (search "compaction-percent: 25" (format-session-settings session))))))

(deftest slash-settings-reflects-and-updates-the-current-session ()
  (with-temp-config-dir ()
    (let ((session (make-session (make-instance 'ollama-provider)))
          (output (make-string-output-stream)))
      (let ((*standard-output* output))
        (dispatch-slash-command session "/settings set compaction_percent 30")
        (dispatch-slash-command session "/settings get compaction-percent"))
      (check-equal (session-context-compaction-threshold session) 0.3)
      (check (search "compaction-percent: 30" (get-output-stream-string output))))))
