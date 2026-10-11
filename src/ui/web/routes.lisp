;;;; ui/web/routes.lisp -- the web frontend's built-in HTTP routes.
;;;;
;;;;   GET  /                      the page          GET /safe   built-ins only
;;;;   GET  /assets/PATH           a layered asset   (see assets.lisp)
;;;;   GET  /safe/assets/PATH      a built-in asset
;;;;   GET  /api/state             full snapshot     (/api/messages: older name)
;;;;   GET  /api/events?since=N    Server-Sent Events after N
;;;;   GET  /api/complete?text=&cursor=   tab completion (completion.lisp)
;;;;   GET  /api/tools             the session's tools
;;;;   GET  /api/ui/assets         assets, overrides, patches, history
;;;;   POST /api/send              {text} or text=...: a line of input
;;;;   POST /api/interrupt         stop the running turn
;;;;   POST /api/quit              end the session
;;;;   POST /api/ui/reset          {path, to: "builtin"|"previous"} or {all: true}
;;;;   POST /api/subagents/cancel  {id}
;;;;
;;;; POSTs must carry X-CL-Agent (see server.lisp).  Extensions add their
;;;; own with DEFINE-WEB-ROUTE, conventionally under /api/ext/.

(in-package :cl-agent)

(defun web-html (html)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  html)

(defun web-serve-asset (prefix &key safe)
  (let ((path (subseq (web-request-path) (length prefix))))
    (multiple-value-bind (content layer) (find-web-asset path :safe safe)
      (cond (content
             (setf (hunchentoot:content-type*) (web-asset-content-type path)
                   (hunchentoot:header-out "X-CL-Agent-Layer") (string-downcase layer))
             content)
            (t (web-respond 404 (jobj "error" (format nil "No asset ~a" path))))))))

(defun web-input-text ()
  "The text of a /api/send request, from a JSON body or a form field."
  (or (web-param "text")
      (let ((text (jget (web-json-body) "text")))
        (and (stringp text) text))))

(define-web-route index (:path "/") (web-html (web-index-html)))
(define-web-route safe-index (:path "/safe") (web-html (web-index-html :safe t)))
(define-web-route assets (:prefix "/assets/") (web-serve-asset "/assets/"))
(define-web-route safe-assets (:prefix "/safe/assets/") (web-serve-asset "/safe/assets/" :safe t))

(define-web-route state (:path "/api/state")
  (setf (hunchentoot:content-type*) "application/json; charset=utf-8")
  (web-frontend-status-json *web-frontend* :safe (web-param "safe")))

(define-web-route messages (:path "/api/messages")
  (setf (hunchentoot:content-type*) "application/json; charset=utf-8")
  (web-frontend-status-json *web-frontend*))

(define-web-route events (:path "/api/events")
  ;; A reconnecting EventSource reports the last id it saw; prefer it to the
  ;; (older) since= it was first opened with.
  (flet ((as-integer (text) (or (and text (parse-integer text :junk-allowed t)) 0)))
    (web-frontend-serve-events *web-frontend*
                               (max (as-integer (web-param "since"))
                                    (as-integer (hunchentoot:header-in* :last-event-id))))))

(define-web-route send (:method :post :path "/api/send")
  (let ((text (web-input-text)))
    (if (and text (plusp (length (string-trim '(#\Space #\Tab #\Newline) text))))
        (jobj "status" (string-downcase (symbol-name (web-frontend-submit *web-frontend* text))))
        (web-respond 400 (jobj "error" "Nothing to send.")))))

(define-web-route interrupt (:method :post :path "/api/interrupt")
  (frontend-request-interrupt *web-frontend*)
  (jobj "status" "ok"))

(define-web-route quit (:method :post :path "/api/quit")
  (trivial-channels:sendmsg (web-frontend-input-channel *web-frontend*) nil)
  (jobj "status" "ok"))

(define-web-route complete (:path "/api/complete")
  (let* ((text (or (web-param "text") ""))
         (cursor (or (parse-integer (or (web-param "cursor") "") :junk-allowed t) (length text))))
    (completion-result-json
     (complete-input text (max 0 (min cursor (length text)))
                     :session (web-frontend-session *web-frontend*)))))

(define-web-route tools (:path "/api/tools")
  (let* ((session (web-frontend-session *web-frontend*))
         (enabled (and session (mapcar #'tool-name (session-tools session)))))
    (jobj "tools"
          (jarray
           (mapcar (lambda (tool)
                     (jobj "name" (tool-name tool)
                           "description" (tool-description tool)
                           "effects" (jarray (mapcar (lambda (e) (string-downcase (string e)))
                                                     (tool-effects tool)))
                           "owner" (json-or-null (tool-owner tool))
                           "enabled" (or (null session) (and (member (tool-name tool) enabled :test #'string=) t))))
                   (sort (list-tools) #'string< :key #'tool-name))))))

(define-web-route ui-assets (:path "/api/ui/assets")
  (jobj "directory" (namestring (web-ui-directory))
        "assets" (jarray
                  (mapcar (lambda (asset)
                            (jobj "path" (getf asset :path)
                                  "layer" (string-downcase (string (getf asset :layer)))
                                  "bytes" (getf asset :bytes)
                                  "builtin" (getf asset :builtin-p)
                                  "patch" (getf asset :patch-p)
                                  "history" (getf asset :history)))
                          (list-web-assets)))))

(define-web-route ui-reset (:method :post :path "/api/ui/reset")
  (let* ((body (web-json-body))
         (path (jget body "path")))
    (cond ((jget body "all")
           (jobj "reset" (jarray (reset-all-web-assets))))
          ((stringp path)
           (jobj "message" (reset-web-asset path :to (if (equal (jget body "to") "previous")
                                                         :previous :builtin))))
          (t (web-respond 400 (jobj "error" "Give a path, or all: true."))))))

(define-web-route cancel-subagent (:method :post :path "/api/subagents/cancel")
  (let ((id (jget (web-json-body) "id")))
    (cancel-subagent-task (find-subagent-task id))
    (jobj "status" "cancelled" "id" id)))
