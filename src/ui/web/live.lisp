;;;; ui/web/live.lisp -- live sessions: several agents at once, each with its
;;;; own working directory, model, tools, subagents and conversation, shown
;;;; as vertical tabs down the page's left edge (static/live.js).  See
;;;; docs/live-sessions.md.
;;;;
;;;; The first session is the one the process started with (run-repl on the
;;;; main thread, its frontend owning the HTTP server).  Each one started
;;;; beside it gets a WEB-FRONTEND of its own -- its own transcript, activity,
;;;; event log and input queue -- registered with the first's server (its
;;;; HUB), and its own thread running RUN-REPL (not :primary), so sessions
;;;; never wait on each other.  A request names its session by live id
;;;; (X-CL-Agent-Session, or ?session= for an event stream); one that names
;;;; none is the first's, so pages and scripts that know nothing of live
;;;; sessions work as before.
;;;;
;;;;   GET  /api/live                 {sessions: [...], current}
;;;;   POST /api/live                 {directory, model?, name?}: start one; {id}
;;;;   POST /api/live/close           {id}: stop one (not the first); its log stays

(in-package :cl-agent)

(defvar *live-session-factory* nil
  "A function (&key frontend model directory) -> a new AGENT-SESSION made
as the first was (main.lisp sets it), or NIL where live sessions are off.")

(defun primary-web-frontend (&optional (frontend *web-frontend*))
  (and frontend (or (web-frontend-hub frontend) frontend)))

(defun live-frontends (&optional (primary (primary-web-frontend)))
  "The live sessions' frontends: the first, then the others as started."
  (and primary
       (cons primary
             (reverse (remove-if-not (lambda (frontend) (eq (web-frontend-hub frontend) primary))
                                     *web-frontends*)))))

(defun find-live-frontend (id &optional (primary (primary-web-frontend)))
  (find id (live-frontends primary) :key #'web-frontend-live-id :test #'equal))

(defun live-session-json (frontend)
  (let* ((session (web-frontend-session frontend))
         (directory (and session (or (session-working-directory session) (uiop:getcwd)))))
    (jobj "id" (web-frontend-live-id frontend)
          "primary" (null (web-frontend-hub frontend))
          "name" (or (and session (session-display-name session))
                     (and directory (car (last (pathname-directory directory))))
                     "session")
          "directory" (json-or-null (and directory (uiop:native-namestring directory)))
          "model" (json-or-null (and session (ignore-errors (provider-model (session-provider session)))))
          "session" (json-or-null (and session (ignore-errors (princ-to-string (session-id session)))))
          "busy" (and (frontend-busy-p frontend) t)
          "messages" (with-web-state (frontend) (length (web-frontend-transcript frontend))))))

(defun start-live-session (&key directory model name)
  "Start a live session beside the first, working in DIRECTORY with MODEL
(else the first's), named NAME.  Returns its frontend once it is serving."
  (let ((primary (primary-web-frontend)))
    (unless (and primary *live-session-factory*)
      (error "Live sessions need the web UI (cl-agent --ui web)."))
    (let* ((directory (or (uiop:directory-exists-p (expand-user-path (or directory (uiop:native-namestring (current-directory)))))
                          (error "There is no directory ~a." directory)))
           (frontend (make-instance 'web-frontend :hub primary))
           (session (funcall *live-session-factory* :frontend frontend :model model :directory directory))
           (config *config-directory*))
      (when (and (stringp name) (plusp (length (string-trim " " name))))
        (rename-session session name))
      (bt:make-thread
       (lambda ()
         (let ((*config-directory* config))
           ;; Its whole life guarded: whatever ends it, the process goes on.
           (with-turn-guard (:where (format nil "Live session ~a" (web-frontend-live-id frontend)))
             (run-repl session :primary nil))))
       :name (format nil "cl-agent live session ~a" (web-frontend-live-id frontend)))
      ;; Serving once UI-START has registered it.
      (loop repeat 200
            until (member frontend *web-frontends*)
            do (sleep 0.01))
      frontend)))

(defun stop-live-session (frontend)
  "Stop live session FRONTEND (never the first): its turn is interrupted,
its loop ends, its durable log stays (the Sessions tab)."
  (unless (web-frontend-hub frontend)
    (error "The first session is the agent's own: quit cl-agent to stop it."))
  (ignore-errors (setf (frontend-interrupt-flag frontend) t))
  ;; NIL at the prompt ends RUN-REPL.
  (trivial-channels:sendmsg (web-frontend-input-channel frontend) nil)
  (loop repeat 300
        while (member frontend *web-frontends*)
        do (sleep 0.01))
  t)

(define-web-route live-sessions (:path "/api/live")
  (jobj "sessions" (jarray (mapcar #'live-session-json (live-frontends)))
        "current" (web-frontend-live-id *web-frontend*)
        "enabled" (and *live-session-factory* t)))

(define-web-route live-session-start (:method :post :path "/api/live")
  (let ((body (web-json-body)))
    (handler-case
        (let ((frontend (start-live-session :directory (jget body "directory")
                                            :model (let ((model (jget body "model")))
                                                     (and (stringp model) (plusp (length model)) model))
                                            :name (jget body "name"))))
          (live-session-json frontend))
      (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))

(define-web-route live-session-close (:method :post :path "/api/live/close")
  (let ((frontend (find-live-frontend (jget (web-json-body) "id"))))
    (cond ((null frontend) (web-respond 404 (jobj "error" "There is no such live session.")))
          (t (handler-case (progn (stop-live-session frontend) (jobj "closed" (web-frontend-live-id frontend)))
               (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))))
