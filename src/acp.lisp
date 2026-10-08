;;;; acp.lisp -- ACP (Agent Client Protocol) adapter for cl-agent.
;;;;
;;;; MCP exposes cl-agent's tools to another agent.  ACP is deliberately a
;;;; separate surface: it exposes a complete cl-agent conversation to an
;;;; editor/client, using agentcomms for the protocol machinery.

(in-package :cl-agent)

(defclass acp-session-record ()
  ((session :initarg :session :reader acp-record-session)
   (cwd :initarg :cwd :reader acp-record-cwd)))

(defclass cl-agent-acp-agent (agentcomms:acp-agent)
  ((provider-factory :initarg :provider-factory :reader acp-provider-factory)
   (session-options :initarg :session-options :initform nil :reader acp-session-options)
   ;; AGENTCOMMS owns ACP protocol session bookkeeping.  This table owns the
   ;; corresponding cl-agent runtime sessions.
   (runtime-sessions :initform (make-hash-table :test #'equal)
                     :reader acp-runtime-sessions)
   (runtime-lock :initform (bordeaux-threads:make-lock "cl-agent ACP sessions")
                 :reader acp-runtime-lock)))

(defclass acp-frontend (queued-input-mixin)
  ((agent :initarg :agent :reader acp-frontend-agent)
   (session-id :initarg :session-id :reader acp-frontend-session-id)
   (streamed-p :initform nil :accessor acp-frontend-streamed-p)))

(defun acp-send-text-update (frontend constructor text)
  (when (plusp (length text))
    (agentcomms:agent-send-update (acp-frontend-agent frontend)
                                  (acp-frontend-session-id frontend)
                                  (funcall constructor (agentcomms:acp-text-content text)))))

(defmethod ui-assistant-delta ((frontend acp-frontend) chunk)
  (setf (acp-frontend-streamed-p frontend) t)
  (acp-send-text-update frontend #'agentcomms:acp-update-agent-message chunk))

(defmethod ui-assistant-text ((frontend acp-frontend) text)
  ;; CHAT-STREAM reports the final complete answer after its deltas.  Sending
  ;; it again would duplicate every streamed answer in ACP clients.
  (unless (acp-frontend-streamed-p frontend)
    (acp-send-text-update frontend #'agentcomms:acp-update-agent-message text)))

(defmethod ui-system ((frontend acp-frontend) text)
  (acp-send-text-update frontend #'agentcomms:acp-update-agent-thought text))

(defmethod ui-error ((frontend acp-frontend) condition)
  (acp-send-text-update frontend #'agentcomms:acp-update-agent-thought
                        (format nil "[error] ~a" condition)))

(defmethod ui-tool-started ((frontend acp-frontend) tool-name arguments)
  (acp-send-text-update frontend #'agentcomms:acp-update-agent-thought
                        (tool-call-summary tool-name arguments)))

(defmethod ui-tool-finished ((frontend acp-frontend) tool-name arguments result)
  (declare (ignore tool-name arguments))
  (acp-send-text-update frontend #'agentcomms:acp-update-agent-thought result))

(defun acp-runtime-record (agent session-id)
  (bordeaux-threads:with-lock-held ((acp-runtime-lock agent))
    (gethash session-id (acp-runtime-sessions agent))))

(defun acp-allocate-session-id (agent)
  (idsmall:identifier-generate
   :namespace :cl-agent-acp-session
   :occupied-p (lambda (identifier) (acp-runtime-record agent identifier))))

(defun acp-prompt-text (prompt)
  "Extract the supported textual ACP blocks, preserving their order."
  (let ((parts (loop for block in prompt
                     for type = (agentcomms:json-get block "type")
                     when (string= type "text")
                       collect (agentcomms:json-get block "text"))))
    (unless parts
      (error "cl-agent ACP currently accepts a prompt containing at least one text block."))
    (format nil "~{~a~^~%~}" parts)))

(defmethod agentcomms:agent-implementation ((agent cl-agent-acp-agent))
  (declare (ignore agent))
  (agentcomms:acp-implementation "cl-agent" "0.1.0" :title "cl-agent"))

(defmethod agentcomms:agent-capabilities ((agent cl-agent-acp-agent))
  (declare (ignore agent))
  ;; These operations are genuinely available for the lifetime of this ACP
  ;; server; durable restore remains the existing /session command for now.
  (agentcomms:acp-agent-capabilities :list t :delete t :close t))

(defmethod agentcomms:agent-new-session ((agent cl-agent-acp-agent)
                                           &key cwd mcp-servers additional-directories params)
  (declare (ignore mcp-servers additional-directories params))
  (let* ((session-id (acp-allocate-session-id agent))
         (frontend (make-instance 'acp-frontend :agent agent :session-id session-id))
         (session (apply #'make-session (funcall (acp-provider-factory agent))
                         :frontend frontend (acp-session-options agent))))
    (bordeaux-threads:with-lock-held ((acp-runtime-lock agent))
      (setf (gethash session-id (acp-runtime-sessions agent))
            (make-instance 'acp-session-record :session session :cwd cwd)))
    (values session-id nil)))

(defmethod agentcomms:agent-prompt ((agent cl-agent-acp-agent) session-id prompt params)
  (declare (ignore params))
  (let ((record (or (acp-runtime-record agent session-id)
                    (error "Unknown ACP session ~a." session-id))))
    (agentcomms:agent-check-cancelled agent session-id)
    (let ((frontend (session-frontend (acp-record-session record))))
      (setf (acp-frontend-streamed-p frontend) nil)
      ;; Relative pathname operations in hooks and tools now resolve against
      ;; the workspace the ACP client selected, without mutating the process
      ;; CWD (which would race other live ACP sessions).
      (let ((*default-pathname-defaults*
              (uiop:ensure-directory-pathname (acp-record-cwd record))))
        (session-submit-user-text (acp-record-session record) (acp-prompt-text prompt))
        (run-agent-turn (acp-record-session record)))
      (agentcomms:agent-check-cancelled agent session-id)
      :end-turn)))

(defmethod agentcomms:agent-cancel ((agent cl-agent-acp-agent) session-id)
  (let ((record (acp-runtime-record agent session-id)))
    (when record
      (frontend-request-interrupt (session-frontend (acp-record-session record)))))
  nil)

(defmethod agentcomms:agent-close-session ((agent cl-agent-acp-agent) session-id params)
  (declare (ignore params))
  (agentcomms:agent-cancel agent session-id)
  (bordeaux-threads:with-lock-held ((acp-runtime-lock agent))
    (remhash session-id (acp-runtime-sessions agent)))
  nil)

(defmethod agentcomms:agent-delete-session ((agent cl-agent-acp-agent) session-id params)
  (declare (ignore params))
  (agentcomms:agent-cancel agent session-id)
  (bordeaux-threads:with-lock-held ((acp-runtime-lock agent))
    (remhash session-id (acp-runtime-sessions agent)))
  nil)

(defmethod agentcomms:agent-list-sessions ((agent cl-agent-acp-agent) &key cwd cursor params)
  (declare (ignore cursor params))
  (values
   (bordeaux-threads:with-lock-held ((acp-runtime-lock agent))
     (loop for session-id being the hash-keys of (acp-runtime-sessions agent) using (hash-value record)
           when (or (null cwd) (string= cwd (acp-record-cwd record)))
             collect (agentcomms:acp-session-info session-id (acp-record-cwd record))))
   nil))

(defun make-cl-agent-acp-agent (provider-factory &key session-options)
  "Create an ACP peer. PROVIDER-FACTORY must return a fresh provider per session."
  (make-instance 'cl-agent-acp-agent :provider-factory provider-factory
                 :session-options session-options))

(defun run-cl-agent-acp-server (provider-factory &key session-options)
  "Serve cl-agent as an ACP peer over standard input/output."
  (agentcomms:acp-serve-standard-io
   (make-cl-agent-acp-agent provider-factory :session-options session-options)))
