;;;; ACP adapter tests exercise the real agentcomms in-memory transport.

(in-package :cl-agent)

(defclass acp-test-provider (llm-provider) ())
(defmethod provider-default-model ((provider acp-test-provider))
  (declare (ignore provider)) "acp-test")
(defmethod provider-display-name ((provider acp-test-provider))
  (declare (ignore provider)) "ACP test")
(defmethod chat ((provider acp-test-provider) messages tools)
  (declare (ignore provider tools))
  (list :role "assistant" :content
        (format nil "ACP: ~a" (getf (car (last messages)) :content))
        :tool-calls nil :usage nil))

(defclass acp-recording-client (agentcomms:acp-client)
  ((updates :initform nil :accessor acp-client-updates)))

(defmethod agentcomms:client-session-update ((client acp-recording-client) session-id update params)
  (declare (ignore params))
  (push (list session-id update) (acp-client-updates client)))

(deftest acp-server-creates-prompts-lists-and-deletes-sessions ()
  (multiple-value-bind (client-channel agent-channel)
      (agentcomms:make-acp-channel-pair)
    (let* ((agent (make-cl-agent-acp-agent
                   (lambda () (make-instance 'acp-test-provider :model "acp-test"))))
           (client (make-instance 'acp-recording-client)))
      (agentcomms:acp-agent-connect agent agent-channel :name "cl-agent ACP test")
      (agentcomms:acp-client-connect client client-channel :name "ACP test client")
      (unwind-protect
           (progn
             (agentcomms:client-initialize client)
             (multiple-value-bind (session-id ignored)
                 (agentcomms:client-new-session client "/tmp")
               (declare (ignore ignored))
               (check (stringp session-id))
               (check-equal (agentcomms:client-prompt
                             client session-id (list (agentcomms:acp-text-content "hello")))
                            :end-turn)
               (check (some (lambda (entry)
                              (search "ACP: hello"
                                      (agentcomms:json-get (agentcomms:json-get (second entry) "content") "text")))
                            (acp-client-updates client)))
               (multiple-value-bind (sessions next) (agentcomms:client-list-sessions client :cwd "/tmp")
                 (check-equal next nil)
                 (check-equal (length sessions) 1))
               (agentcomms:client-delete-session client session-id)
               (multiple-value-bind (sessions next) (agentcomms:client-list-sessions client :cwd "/tmp")
                 (check-equal next nil)
                 (check-equal sessions nil))))
        (ignore-errors (agentcomms:connection-close (agentcomms:acp-client-connection client)))
        (ignore-errors (agentcomms:connection-close (agentcomms:acp-agent-connection agent)))
        (ignore-errors (agentcomms:channel-close client-channel))
        (ignore-errors (agentcomms:channel-close agent-channel))))))
