;;;; ui/web/server.lisp -- the HTTP layer of the web frontend: an acceptor,
;;;; a route registry, and request/response helpers.
;;;;
;;;; Routes are data, like tools and slash commands: DEFINE-WEB-ROUTE adds
;;;; one to *WEB-ROUTES*, so an extension (or the agent itself, via
;;;; write-extension) can give the page a new JSON endpoint without
;;;; touching this file -- pair it with a patches/*.js asset that calls
;;;; CLAgent.api("/api/ext/...") and renders the result (static/EXTENDING.md
;;;; walks through exactly that).  Routes registered by an extension are
;;;; rolled back with the rest of a failed mutation.
;;;;
;;;; Each acceptor carries its own WEB-FRONTEND and binds *WEB-FRONTEND*
;;;; around every request, so route bodies simply use *WEB-FRONTEND* and
;;;; several frontends (as in the test suite) never see each other.
;;;;
;;;; Safety: the server listens on 127.0.0.1 only, rejects requests whose
;;;; Host header is not a loopback name (DNS rebinding), and refuses any
;;;; non-GET request lacking the X-CL-Agent header.  Browsers cannot add a
;;;; custom header to a cross-origin request without a CORS preflight, which
;;;; this server never grants, so another web page cannot drive the agent
;;;; (or rewrite its UI) through the user's browser.

(in-package :cl-agent)

(defvar *web-frontend* nil
  "The WEB-FRONTEND serving the current request (bound per request by the
acceptor), or outside a request the most recently started one.")

(defvar *web-frontends* nil
  "Every started WEB-FRONTEND; WEB-UI-BROADCAST reaches all of them.")

(defstruct web-route name method path prefix-p handler owner)

(defvar *web-routes* (make-hash-table :test 'equal)
  "Route name (string) -> WEB-ROUTE.")

(defun register-web-route (name method path prefix-p handler)
  "Register HANDLER (a function of no arguments) for METHOD requests to PATH,
or to every path beginning with PATH when PREFIX-P.  Re-registering NAME
replaces the earlier route."
  (let ((name (string-downcase (string name))))
    (unless (and (stringp path) (plusp (length path)) (char= (char path 0) #\/))
      (error "Web route path must start with /: ~s" path))
    (setf (gethash name *web-routes*)
          (make-web-route :name name :method method :path path :prefix-p prefix-p
                          :handler handler :owner (or *registration-owner* "core")))
    (publish-component :web-route name :owner (or *registration-owner* "core")
                       :metadata (list :method method :path path :prefix prefix-p))
    name))

(defmacro define-web-route (name (&key (method :get) path prefix) &body body)
  "Serve BODY at PATH (exact) or under PREFIX (any path starting with it).
METHOD is :GET, :POST or :ANY.  Inside BODY, *WEB-FRONTEND* is the frontend
being served; use WEB-PARAM / WEB-JSON-BODY to read the request.  BODY's value
is the response: a hash table or list (sent as JSON), a string (sent as is,
with whatever content type BODY set), or NIL (an empty JSON object).

  (define-web-route weather (:path \"/api/ext/weather\")
    (jobj \"city\" (web-param \"city\") \"temp\" 21))"
  `(register-web-route ',name ,method ,(or path prefix) ,(and prefix t)
                       (lambda () ,@body)))

(defun unregister-web-route (name)
  (let ((name (string-downcase (string name))))
    (when (remhash name *web-routes*)
      (unpublish-component :web-route name)
      t)))

(defun find-web-route (method path)
  "The exact-path route for PATH, else the longest matching prefix route."
  (let ((best nil))
    (loop for route being the hash-values of *web-routes*
          when (and (or (eq (web-route-method route) :any)
                        (eq (web-route-method route) method)
                        (and (eq method :head) (eq (web-route-method route) :get))))
            do (cond ((and (not (web-route-prefix-p route)) (string= path (web-route-path route)))
                      (return-from find-web-route route))
                     ((and (web-route-prefix-p route)
                           (uiop:string-prefix-p (web-route-path route) path)
                           (or (null best)
                               (> (length (web-route-path route)) (length (web-route-path best)))))
                      (setf best route))))
    best))

;;; --- Request helpers for route bodies ---

(defun web-param (name)
  "The query-string or form parameter NAME of the current request, or NIL."
  (hunchentoot:parameter name))

(defun web-json-body ()
  "The current request body decoded as a JSON object (empty if absent/invalid)."
  (let ((text (hunchentoot:raw-post-data :force-text t)))
    (if (and text (plusp (length text)))
        (values (decode-json-object text))
        (jobj))))

(defun web-request-path () (hunchentoot:script-name*))

(defun web-respond (status object)
  "Set the HTTP STATUS and return OBJECT for the route to send."
  (setf (hunchentoot:return-code*) status)
  object)

(defun jarray (list)
  "LIST as a JSON array, including the empty one (see JOBJ on NIL)."
  (or list :empty-array))

(defun json-or-null (value) (if (null value) :null value))

;;; --- Acceptor ---

(defclass web-ui-acceptor (hunchentoot:acceptor)
  ((frontend :initarg :frontend :reader web-ui-acceptor-frontend))
  (:default-initargs :access-log-destination nil)
  (:documentation "Loopback hunchentoot acceptor dispatching to *WEB-ROUTES*."))

(defun loopback-host-p (host)
  "True when HOST (a Host header value) names this machine's loopback interface."
  (let* ((host (string-downcase (or host "")))
         (name (if (and (plusp (length host)) (char= (char host 0) #\[))
                   (subseq host 0 (1+ (or (position #\] host) (1- (length host)))))
                   (subseq host 0 (or (position #\: host) (length host))))))
    (member name '("127.0.0.1" "localhost" "[::1]") :test #'string=)))

(defun web-request-trusted-p ()
  "True for a same-origin script request (see this file's header comment)."
  (and (hunchentoot:header-in* :x-cl-agent)
       (let ((origin (hunchentoot:header-in* :origin)))
         (or (null origin)
             (loopback-host-p (subseq origin (min (length origin) (+ 3 (or (search "://" origin) -3)))))))))

(defun web-route-response (value)
  (cond ((stringp value) value)
        ((or (hash-table-p value) (consp value))
         (setf (hunchentoot:content-type*) "application/json; charset=utf-8")
         (json-encode value))
        (t (setf (hunchentoot:content-type*) "application/json; charset=utf-8") "{}")))

(defun web-error-response (status message)
  (setf (hunchentoot:return-code*) status
        (hunchentoot:content-type*) "application/json; charset=utf-8")
  (json-encode (jobj "error" message)))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor web-ui-acceptor) request)
  (let* ((*web-frontend* (web-ui-acceptor-frontend acceptor))
         (*config-directory* (web-frontend-config-directory *web-frontend*))
         (method (hunchentoot:request-method request))
         (path (hunchentoot:script-name request)))
    (setf (hunchentoot:header-out "Cache-Control") "no-store")
    (cond
      ((not (loopback-host-p (hunchentoot:host request)))
       (web-error-response 403 "This server only answers requests addressed to localhost."))
      (t
       (let ((route (find-web-route method path)))
         (cond
           ((null route) (web-error-response 404 (format nil "No route for ~a ~a" method path)))
           ((and (not (member method '(:get :head))) (not (web-request-trusted-p)))
            (web-error-response 403 "Mutating requests need the X-CL-Agent header (same-origin scripts only)."))
           (t
            (handler-case (web-route-response (funcall (web-route-handler route)))
              (error (condition)
                (web-error-response 500 (princ-to-string condition)))))))))))

(defun web-port-in-use-p (condition)
  "True when CONDITION is the platform's report of an occupied listen port."
  (let ((text (string-downcase (princ-to-string condition))))
    (or (search "address already in use" text)
        (search "address in use" text)
        (search "address-in-use" text)
        (search "eaddrinuse" text))))

(defun start-web-acceptor (frontend)
  "Start FRONTEND on its preferred port or one of the next 100 ports."
  (loop for port from (web-frontend-port frontend) below (+ (web-frontend-port frontend) 100)
        do (handler-case
               (let ((acceptor (make-instance 'web-ui-acceptor :port port :address "127.0.0.1"
                                                               :frontend frontend)))
                 (hunchentoot:start acceptor)
                 (setf (web-frontend-port frontend) port)
                 (return acceptor))
             (error (condition)
               (unless (web-port-in-use-p condition)
                 (error condition))))
        finally (error "Could not find a free web UI port starting at ~d."
                       (web-frontend-port frontend))))
