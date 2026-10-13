;;;; t/test-session-tools.lisp -- a session's tools follow the registry
;;;; (repl.lisp SYNC-SESSION-TOOLS): an MCP server connected by a startup
;;;; hook or by the model mid-turn is offered to the model and shown as
;;;; available in the web UI, not just callable by a name the model guessed.

(in-package :cl-agent)

(defun register-test-tool (name &optional (description "a test tool"))
  (register-tool (make-instance 'tool :name name :description description
                                      :handler (lambda (args) (declare (ignore args)) "ok"))))

(defmacro with-test-tools-cleanup ((&rest names) &body body)
  `(unwind-protect (progn ,@body)
     (dolist (name (list ,@names)) (unregister-tool name))))

(defun tool-named-p (name tools)
  (and (find name tools :key #'tool-name :test #'string=) t))

(deftest a-session-picks-up-tools-registered-after-it-started ()
  (with-test-tools-cleanup ("test-late-tool")
    (let* ((frontend (make-instance 'steer-frontend))
           (session (make-session (make-instance 'ollama-provider) :frontend frontend)))
      (check (session-follows-registry session))
      (check (null (sync-session-tools session)) "nothing new yet")
      (register-test-tool "test-late-tool")
      (check-equal (mapcar #'tool-name (sync-session-tools session)) '("test-late-tool"))
      (check (tool-named-p "test-late-tool" (session-tools session)) "offered to the model")
      (check (tool-named-p "test-late-tool" (session-tool-catalog session)))
      (check (null (sync-session-tools session)) "announced once")
      (check-equal (count-if (lambda (line) (search "test-late-tool" line)) (steer-lines frontend)) 1)
      (let ((redefined (register-test-tool "test-late-tool" "a new definition")))
        (sync-session-tools session)
        (check (find redefined (session-tools session)) "a redefinition replaces the old tool"))
      (unregister-tool "test-late-tool")
      (sync-session-tools session)
      (check (not (tool-named-p "test-late-tool" (session-tools session))) "a removed tool is not offered")
      (check (search "No longer available" (first (steer-lines frontend)))))))

(deftest a-session-with-its-own-tool-list-keeps-to-it ()
  (with-test-tools-cleanup ("test-own-tool" "test-other-tool")
    (let ((session (make-session (make-instance 'ollama-provider) :frontend (make-instance 'steer-frontend)
                                 :tools (list (register-test-tool "test-own-tool")))))
      (check (not (session-follows-registry session)))
      (register-test-tool "test-other-tool")
      (sync-session-tools session)
      (check-equal (mapcar #'tool-name (session-tools session)) '("test-own-tool")))))

(deftest plan-mode-leaves-new-tools-to-discover-tools ()
  (with-test-tools-cleanup ("test-planned-tool")
    (let ((session (make-session (make-instance 'ollama-provider) :frontend (make-instance 'steer-frontend)
                                 :orchestration-mode :plan)))
      (setf (session-tools session) (list (find-tool "discover-tools")))
      (register-test-tool "test-planned-tool")
      (sync-session-tools session)
      (check (tool-named-p "test-planned-tool" (session-tool-catalog session)) "discoverable")
      (check-equal (mapcar #'tool-name (session-tools session)) '("discover-tools") "but not yet offered"))))

(defclass tool-recording-provider (steer-provider)
  ((offered :initform nil :accessor offered-tool-names)))
(defmethod chat :before ((provider tool-recording-provider) messages tools)
  (declare (ignore messages))
  (push (mapcar #'tool-name tools) (offered-tool-names provider)))

(deftest a-tool-registered-mid-turn-is-offered-on-the-next-request ()
  ;; What connect-mcp-server does when the model calls it.
  (with-test-tools-cleanup ("test-connect-later" "test-mcp-tool")
    (register-tool (make-instance 'tool :name "test-connect-later" :description "connects a server"
                                        :handler (lambda (args) (declare (ignore args))
                                                   (register-test-tool "test-mcp-tool")
                                                   "Connected: 1 tool registered.")))
    (let* ((provider (make-instance 'tool-recording-provider :model "m"
                                    :script (list (lambda ()
                                                    (list :role "assistant" :content nil
                                                          :tool-calls (list (list :id "c1" :name "test-connect-later"
                                                                                  :arguments (jobj)))))
                                                  (lambda () (list :role "assistant" :content "done" :tool-calls nil)))))
           (session (make-session provider :frontend (make-instance 'steer-frontend))))
      (setf (session-messages session)
            (append (session-messages session) (list (list :role "user" :content "connect it"))))
      (check-equal (getf (run-agent-turn session) :content) "done")
      (destructuring-bind (second first) (offered-tool-names provider)
        (check (not (member "test-mcp-tool" first :test #'string=)))
        (check (member "test-mcp-tool" second :test #'string=) "the new tool's schema reaches the model")))))

(deftest web-tools-route-shows-late-tools-as-offered ()
  (with-test-tools-cleanup ("test-web-late-tool")
    (with-test-web-frontend (frontend)
      (let ((session (make-session (make-instance 'ollama-provider) :frontend frontend)))
        (setf (web-frontend-session frontend) session)
        (register-test-tool "test-web-late-tool")
        (let ((entry (find "test-web-late-tool" (gethash "tools" (web-get-json frontend "/api/tools"))
                           :key (lambda (tool) (gethash "name" tool)) :test #'equal)))
          (check entry)
          (check (gethash "enabled" entry) "not listed as unavailable"))
        (check (some (lambda (event) (search "\"type\":\"tools\"" (cdr event))) (web-frontend-events frontend))
               "the page is told to refetch")))))
