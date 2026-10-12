;;;; ui/web/session-routes.lisp -- picking up where you left off, and
;;;; choosing the model, from the page instead of the terminal.
;;;;
;;;;   GET  /api/sessions/recent   earlier conversations worth resuming
;;;;   POST /api/sessions/resume   {id}: runs /session resume ID on the agent's
;;;;                               own thread, like typing it
;;;;   GET  /api/models            the provider's models and the current one
;;;;   POST /api/model             {model, remember?}: switch models (REMEMBER
;;;;                               also saves :model in config.lisp)
;;;;
;;;; The page (static/session.js) offers the recent sessions whenever it
;;;; finds an empty conversation -- a fresh start, or the server restarted
;;;; under it -- and asks for a model when *WEB-MODEL-CHOICE-PENDING*.

(in-package :cl-agent)

(defparameter *web-recent-session-limit* 8 "Sessions the page offers to resume.")
(defparameter *web-recent-session-scan-limit* 80
  "Most recently active sessions examined (most hold no conversation).")

(defvar *web-session-summaries* (make-hash-table :test 'equal)
  "(ID . LAST-SEQUENCE) -> summary plist, so each session is read once.")
(defvar *web-session-summaries-lock* (bt:make-lock "cl-agent-web-session-summaries"))

(defun message-text-for-summary (message)
  (let ((content (getf message :content)))
    (if (stringp content) content "")))

(defun durable-session-summary (manifest)
  "(:ID :NAME :TITLE :LAST :MESSAGES :USER-MESSAGES :LAST-ACTIVE) for the
session MANIFEST describes; NIL if its log cannot be read."
  (let* ((id (getf manifest :id))
         (key (cons id (getf manifest :last-sequence))))
    (or (bt:with-lock-held (*web-session-summaries-lock*) (gethash key *web-session-summaries*))
        (let ((summary
                (ignore-errors
                 (let* ((messages (nth-value 1 (replay-session id)))
                        (users (remove "user" messages :key (lambda (m) (getf m :role)) :test-not #'equal)))
                   (list :id id :name (getf manifest :name)
                         :title (first-line (message-text-for-summary (first users)) 90)
                         :last (first-line (message-text-for-summary (car (last users))) 90)
                         :messages (count-if (lambda (m) (member (getf m :role) '("user" "assistant") :test #'equal))
                                             messages)
                         :user-messages (length users)
                         :last-active (universal-to-unix-time
                                       (ignore-errors (file-write-date (session-manifest-pathname id)))))))))
          (when summary
            (bt:with-lock-held (*web-session-summaries-lock*)
              (setf (gethash key *web-session-summaries*) summary)))
          summary))))

(defun recent-durable-sessions (&key exclude (limit *web-recent-session-limit*))
  "Summaries of the most recently active sessions with a conversation,
newest first, leaving out the session EXCLUDE names."
  (let* ((manifests (remove exclude (list-durable-sessions) :key (lambda (m) (getf m :id)) :test #'equal))
         (dated (mapcar (lambda (manifest)
                          (cons (or (ignore-errors (file-write-date (session-manifest-pathname (getf manifest :id)))) 0)
                                manifest))
                        manifests))
         (found nil))
    (loop for (nil . manifest) in (sort dated #'> :key #'car)
          for scanned from 0
          while (and (< scanned *web-recent-session-scan-limit*) (< (length found) limit))
          do (let ((summary (durable-session-summary manifest)))
               (when (and summary (plusp (getf summary :user-messages)))
                 (push summary found))))
    (nreverse found)))

(defun web-session-summary-json (summary)
  (jobj "id" (getf summary :id)
        "name" (json-or-null (getf summary :name))
        "title" (or (getf summary :title) "")
        "last" (or (getf summary :last) "")
        "messages" (getf summary :messages)
        "user_messages" (getf summary :user-messages)
        "last_active" (json-or-null (getf summary :last-active))))

(defun web-current-session-id ()
  (let ((session (web-frontend-session *web-frontend*)))
    (and session (ignore-errors (princ-to-string (session-id session))))))

(define-web-route recent-sessions (:path "/api/sessions/recent")
  (jobj "current" (json-or-null (web-current-session-id))
        "sessions" (jarray (mapcar #'web-session-summary-json
                                   (recent-durable-sessions :exclude (web-current-session-id))))))

(define-web-route resume-session (:method :post :path "/api/sessions/resume")
  (let ((id (jget (web-json-body) "id")))
    (cond ((not (and (stringp id) (plusp (length id))
                     (every (lambda (c) (or (alphanumericp c) (member c '(#\- #\_)))) id)
                     (find id (list-durable-sessions) :key (lambda (m) (getf m :id)) :test #'equal)))
           (web-respond 404 (jobj "error" "There is no such session.")))
          ((frontend-busy-p *web-frontend*)
           (web-respond 409 (jobj "error" "The agent is busy; resume once it is idle.")))
          (t
           (jobj "status" (string-downcase (symbol-name
                                            (web-frontend-submit *web-frontend*
                                                                 (format nil "/session resume ~a" id)))))))))

;;; --- the model ---

(defun web-session-provider ()
  (let ((session (web-frontend-session *web-frontend*)))
    (and session (session-provider session))))

(define-web-route models (:path "/api/models")
  (let ((provider (web-session-provider)))
    (if (null provider)
        (web-respond 503 (jobj "error" "No session is running yet."))
        (multiple-value-bind (models problem)
            (handler-case (values (provider-list-models provider) nil)
              (error (condition) (values nil (princ-to-string condition))))
          (jobj "provider" (provider-display-name provider)
                "current" (provider-model provider)
                "models" (jarray models)
                "error" (json-or-null problem)
                "pending" (and *web-model-choice-pending* t)
                "default" (json-or-null (ignore-errors (getf (load-user-config) :model))))))))

(define-web-route choose-model (:method :post :path "/api/model")
  (let* ((body (web-json-body))
         (model (jget body "model"))
         (session (web-frontend-session *web-frontend*))
         (provider (web-session-provider)))
    (cond
      ((null provider) (web-respond 503 (jobj "error" "No session is running yet.")))
      ((not (and (stringp model) (plusp (length model))))
       (web-respond 400 (jobj "error" "Give a model.")))
      (t
       (let ((models (ignore-errors (provider-list-models provider))))
         (if (and models (not (member model models :test #'string=)))
             (web-respond 404 (jobj "error" (format nil "~a does not offer ~a." (provider-display-name provider) model)))
             (multiple-value-bind (saved problem)
                 (if (jget body "remember")
                     (handler-case (values (namestring (save-config-model model)) nil)
                       (error (condition) (values nil (princ-to-string condition))))
                     (values nil nil))
               (let ((changed (not (equal model (provider-model provider)))))
                 (setf (provider-model provider) model
                       *web-model-choice-pending* nil)
                 (when changed
                   (ui-system *web-frontend* (format nil "Model switched to ~a." model)))
                 (ui-stats-updated *web-frontend* (session-stats-snapshot session))
                 (web-ui-broadcast "model" (jobj "model" model "pending" nil))
                 (jobj "model" model "saved" (json-or-null saved)
                       "error" (json-or-null (and problem (format nil "Switched, but not saved as the default: ~a" problem))))))))))))
