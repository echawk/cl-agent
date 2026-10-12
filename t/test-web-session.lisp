;;;; t/test-web-session.lisp -- resuming sessions and choosing the model
;;;; from the web UI (ui/web/session-routes.lisp, the web frontend's
;;;; UI-CONVERSATION-REPLACED, config.lisp's SAVE-CONFIG-MODEL).

(in-package :cl-agent)

(defclass test-models-provider (ollama-provider) ()
  (:documentation "An Ollama provider whose model list needs no server."))

(defmethod provider-list-models ((provider test-models-provider))
  (list "small-model" "big-model"))

;;; --- saving the model in config.lisp ---

(deftest save-config-model-creates-a-config-when-there-is-none ()
  (save-config-model "big-model")
  (check-equal (getf (load-user-config) :model) "big-model"))

(deftest save-config-model-keeps-comments-and-other-settings ()
  (write-string-atomically (config-file-path)
                           (format nil ";; my settings~%(:provider :ollama~% ;; a note~% :max-tool-iterations 7)~%"))
  (save-config-model "small-model")
  (let ((text (uiop:read-file-string (config-file-path)))
        (config (load-user-config)))
    (check (search ";; my settings" text))
    (check (search ";; a note" text))
    (check-equal (getf config :model) "small-model")
    (check-equal (getf config :provider) :ollama)
    (check-equal (getf config :max-tool-iterations) 7))
  (save-config-model "big-model")
  (check-equal (getf (load-user-config) :model) "big-model" "an existing :model is replaced")
  (check-equal (count-matches ":model" (uiop:read-file-string (config-file-path))) 1))

(defun count-matches (needle haystack)
  (loop with start = 0 for hit = (search needle haystack :start2 start :test #'char-equal)
        while hit count t do (setf start (1+ hit))))

;;; --- recent sessions ---

(deftest recent-durable-sessions-lists-conversations-newest-first ()
  (let ((empty (make-session (make-instance 'ollama-provider)))
        (talked (make-session (make-instance 'ollama-provider))))
    (session-submit-user-text talked "plan the refactor")
    (let ((recent (recent-durable-sessions)))
      (check (find (session-id talked) recent :key (lambda (s) (getf s :id)) :test #'equal))
      (check (not (find (session-id empty) recent :key (lambda (s) (getf s :id)) :test #'equal))
             "a session with no conversation is not offered")
      (check-equal (getf (first recent) :title) "plan the refactor")
      (check-equal (getf (first recent) :user-messages) 1))
    (check (null (recent-durable-sessions :exclude (session-id talked))))))

;;; --- rebuilding the transcript ---

(deftest web-conversation-replaced-rebuilds-the-transcript ()
  (with-test-web-frontend (frontend)
    (web-frontend-push frontend "user" "something from before")
    (let ((session (make-session (make-instance 'ollama-provider))))
      (setf (session-messages session)
            (list (list :role "system" :content "the prompt")
                  (list :role "user" :content "list the files")
                  (list :role "assistant" :content "Looking."
                        :tool-calls (list (list :id "call-1" :name "shell" :arguments (jobj "command" "ls"))))
                  (list :role "tool" :tool-call-id "call-1" :content "a.lisp")
                  (list :role "assistant" :content "There is **a.lisp**.")))
      (ui-conversation-replaced frontend session)
      (let ((transcript (reverse (web-frontend-transcript frontend))))
        (check-equal (mapcar (lambda (e) (getf e :role)) transcript)
                     '("user" "assistant" "tool" "tool" "assistant"))
        (check-equal (getf (first transcript) :text) "list the files")
        (check (search "<strong>a.lisp</strong>" (getf (car (last transcript)) :html)))
        (check-equal (web-frontend-turn frontend) 1))
      (check (find "tool-output" (web-frontend-activity frontend)
                   :key (lambda (e) (getf e :kind)) :test #'equal)
             "tool calls show up in the Activity panel too")
      (check (some (lambda (event) (search "\"type\":\"reset\"" (cdr event))) (web-frontend-events frontend))))))

;;; --- routes ---

(deftest web-session-routes-list-and-resume ()
  (let ((talked (make-session (make-instance 'ollama-provider))))
    (session-submit-user-text talked "remember me")
    (with-test-web-frontend (frontend)
      (let ((sessions (gethash "sessions" (web-get-json frontend "/api/sessions/recent"))))
        (check-equal (gethash "title" (first sessions)) "remember me"))
      (check-equal (nth-value 1 (web-post frontend "/api/sessions/resume" :json (jobj "id" "no-such-session"))) 404)
      (check-equal (nth-value 1 (web-post frontend "/api/sessions/resume" :json (jobj "id" "../etc"))) 404)
      (multiple-value-bind (body status)
          (web-post frontend "/api/sessions/resume" :json (jobj "id" (session-id talked)))
        (check-equal status 200)
        (check-equal (gethash "status" (json-decode body)) "immediate"))
      (check-equal (trivial-channels:recvmsg (web-frontend-input-channel frontend) 1)
                   (format nil "/session resume ~a" (session-id talked))
                   "the resume runs as a command on the agent's thread"))))

(deftest web-model-routes-list-switch-and-remember ()
  (with-test-web-frontend (frontend)
    (check-equal (nth-value 1 (web-get frontend "/api/models")) 503 "no session yet")
    (let* ((provider (make-instance 'test-models-provider))
           (session (make-session provider :frontend frontend))
           (saved-pending *web-model-choice-pending*))
      ;; Request threads see the global value, not a LET binding.
      (setf *web-model-choice-pending* t
            (web-frontend-session frontend) session)
      (check (gethash "model_pending" (gethash "ui" (web-get-json frontend "/api/state"))))
      (let ((models (web-get-json frontend "/api/models")))
        (check-equal (gethash "models" models) '("small-model" "big-model"))
        (check (gethash "pending" models)))
      (check-equal (nth-value 1 (web-post frontend "/api/model" :json (jobj "model" "nope"))) 404)
      (let ((result (json-decode (web-post frontend "/api/model" :json (jobj "model" "big-model" "remember" t)))))
        (check-equal (gethash "model" result) "big-model")
        (check (stringp (gethash "saved" result))))
      (check-equal (provider-model provider) "big-model")
      (check (not *web-model-choice-pending*))
      (check-equal (getf (load-user-config) :model) "big-model")
      (check (find "Model switched to big-model." (web-frontend-transcript frontend)
                   :key (lambda (e) (getf e :text)) :test #'equal))
      (setf *web-model-choice-pending* saved-pending))))
