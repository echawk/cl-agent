;;;; t/test-live-sessions.lisp -- several sessions at once (ui/web/live.lisp,
;;;; workdir.lisp): each its own working directory, transcript and loop,
;;;; routed by live id, over real HTTP.

(in-package :cl-agent)

(deftest a-session-can-have-its-own-working-directory ()
  (let* ((process (uiop:getcwd))
         (own (uiop:ensure-directory-pathname (merge-pathnames "own-dir/" *config-directory*)))
         (other (uiop:ensure-directory-pathname (merge-pathnames "own-dir/sub/" *config-directory*))))
    (ensure-directories-exist other)
    (let ((session (make-session (make-instance 'ollama-provider :model "m") :working-directory own)))
      (let ((*current-session* session))
        (check (uiop:pathname-equal (current-directory) (truename own)) "its own")
        (let ((*error-output* (make-broadcast-stream)))
          (set-working-directory (namestring other)))
        (check (uiop:pathname-equal (current-directory) (truename other)) "/cd moves it")
        (check (uiop:pathname-equal (uiop:getcwd) process) "and only it: the process stays")))
    (let ((first (make-session (make-instance 'ollama-provider :model "m"))))
      (let ((*current-session* first))
        (check (uiop:pathname-equal (current-directory) process) "the first follows the process")))))

(defun live-request (frontend path id &key json)
  (multiple-value-bind (body status)
      (drakma:http-request (web-test-url frontend path)
                           :method (if json :post :get)
                           :additional-headers (append (and id (list (cons "X-CL-Agent-Session" id)))
                                                       '(("X-CL-Agent" . "1")))
                           :content-type "application/json"
                           :content (and json (json-encode json)))
    (values (json-decode (if (stringp body) body (babel:octets-to-string body :encoding :utf-8))) status)))

(defun transcript-text (state)
  (format nil "~{~a~^~%~}" (mapcar (lambda (message) (gethash "text" message)) (gethash "messages" state))))

(defun wait-for-transcript (frontend id text &key (seconds 10))
  (loop repeat (* seconds 20)
        when (search text (transcript-text (live-request frontend "/api/state" id))) return t
        do (sleep 0.05)))

(deftest live-sessions-run-side-by-side ()
  (with-test-web-frontend (primary)
    ;; SETF, not LET: the request threads must see it.
    (setf *live-session-factory*
          (lambda (&key frontend model directory)
            (declare (ignore model))
            (make-session (make-instance 'ollama-provider :model "m") :frontend frontend :working-directory directory)))
    (unwind-protect (let* ((two (uiop:ensure-directory-pathname (merge-pathnames "live-two/" *config-directory*))))
      (ensure-directories-exist two)
      (let* ((started (live-request primary "/api/live" nil :json (jobj "directory" (namestring two) "name" "second")))
             (id (gethash "id" started)))
        (unwind-protect
             (progn
               (check-equal (gethash "name" started) "second")
               (check (search "live-two" (gethash "directory" started)))
               (check-equal (length (gethash "sessions" (live-request primary "/api/live" nil))) 2 "listed beside the first")
               ;; Each request goes to the session it names.
               (check (search "live-two" (gethash "cwd" (live-request primary "/api/cwd" id))) "its own directory")
               (check (not (search "live-two" (gethash "cwd" (live-request primary "/api/cwd" nil)))) "the first's is its own")
               ;; Its own loop answers its input, in its own transcript.
               (live-request primary "/api/send" id :json (jobj "text" "/pwd"))
               (check (wait-for-transcript primary id "live-two") "it ran /pwd in its own directory")
               (check (not (search "live-two" (transcript-text (live-request primary "/api/state" nil))))
                      "nothing of it in the first's transcript"))
          (live-request primary "/api/live/close" nil :json (jobj "id" id)))
        (check-equal (length (gethash "sessions" (live-request primary "/api/live" nil))) 1 "closed")
        (multiple-value-bind (json status) (live-request primary "/api/live/close" nil :json (jobj "id" (web-frontend-live-id primary)))
          (check-equal status 400)
          (check (search "the agent's own" (gethash "error" json)) "the first cannot be closed"))))
      (setf *live-session-factory* nil))))

(deftest a-past-session-reopens-as-a-live-tab ()
  (with-test-web-frontend (primary)
    (setf *live-session-factory*
          (lambda (&key frontend model directory)
            (declare (ignore model))
            (make-session (make-instance 'ollama-provider :model "m") :frontend frontend :working-directory directory)))
    (unwind-protect
         (let* ((there (uiop:ensure-directory-pathname (merge-pathnames "live-past/" *config-directory*)))
                (past (progn (ensure-directories-exist there)
                             (make-session (make-instance 'ollama-provider :model "m") :working-directory there)))
                (id (princ-to-string (session-id past))))
           ;; A conversation from before, in its own directory, since closed.
           (dolist (message (list (list :role "user" :content "remember the walrus")
                                  (list :role "assistant" :content "The walrus is remembered.")))
             (record-session-event past (if (equal (getf message :role) "user") :user-message-accepted :assistant-response-finished)
                                   :component "session" :payload (list :message message)))
           (persist-session-manifest past)
           (remhash id *live-sessions*)
           (let* ((opened (live-request primary "/api/live" nil :json (jobj "resume" id)))
                  (live-id (gethash "id" opened)))
             (unwind-protect
                  (progn
                    (check-equal (gethash "session" opened) id "the same durable session")
                    (check (search "live-past" (gethash "directory" opened)) "in the directory it worked in")
                    (check (search "walrus" (transcript-text (live-request primary "/api/state" live-id)))
                           "its conversation is back, in its own tab")
                    (check-equal (gethash "id" (live-request primary "/api/live" nil :json (jobj "resume" id))) live-id
                                 "opening it again goes to the same tab")
                    (check (search "another live session"
                                   (handler-case (progn (resume-session (web-frontend-session primary) id) "resumed")
                                     (error (c) (princ-to-string c))))
                           "the first cannot resume a log another session is writing"))
               (live-request primary "/api/live/close" nil :json (jobj "id" live-id)))
             (check (not (durable-session-in-use-p id)) "closed, its log is free again")))
      (setf *live-session-factory* nil))))
