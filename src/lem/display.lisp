;;;; lem/display.lisp -- the hosted Lem, shown in the browser by Lem's own
;;;; web frontend: the Code tab's editor *is* Lem (windows, mode line, M-x,
;;;; the minibuffer, dired, the user's init file and keys).
;;;;
;;;; LEM-HOST-DISPLAY is Lem's own JSON-RPC frontend class (lem-server), so
;;;; every view, line and cursor is rendered by Lem's code, unchanged; what
;;;; differs is how it is hosted:
;;;;   - the editor thread is cl-agent's (lem/host.lisp), started without
;;;;     waiting for a browser, and nothing calls UIOP:QUIT on exit;
;;;;   - the websocket server starts on demand (LEM-DISPLAY-URL), on a free
;;;;     port of 127.0.0.1, behind LEM-DISPLAY-CLACK-HANDLER: a loopback Host
;;;;     only (no DNS rebinding), websocket upgrades only from the Lem page's
;;;;     own origin (so no other web page can drive Lem -- browsers always
;;;;     send Origin), and only the client's own files: lem-server's /local/
;;;;     route, which serves any file on disk, is refused;
;;;;   - the client is served with two changes: it no longer pulls focus
;;;;     back into itself on blur (it lives in an iframe beside cl-agent's own
;;;;     inputs), and it takes its font from the page (?font=&size=).

(in-package :cl-agent)

(defclass lem-host-display (lem-server:jsonrpc) ()
  (:documentation "cl-agent's Lem frontend: lem-server's renderer, hosted here."))

(defmethod initialize-instance :after ((display lem-host-display) &key)
  ;; Unbound until a browser logs in, yet Lem asks for them before that.
  (setf (lem-server::jsonrpc-background-color display) (lem:make-color 255 255 255)
        (lem-server::jsonrpc-foreground-color display) (lem:make-color 0 0 0)
        (lem-server::jsonrpc-display-width display) 120
        (lem-server::jsonrpc-display-height display) 40))

(defmethod lem-if:invoke ((display lem-host-display) function)
  ;; FUNCTION starts cl-agent's editor thread and returns it.
  (setf (lem-server::jsonrpc-editor-thread display) (funcall function)))

(defun lem-display-connected-p (&optional (display (lem:implementation)))
  (and (typep display 'lem-host-display)
       (ignore-errors (jsonrpc/server::server-client-connections (lem-server::jsonrpc-server display)))
       t))

(defmethod lem-if:js-eval ((display lem-host-display) view code &key wait)
  ;; Waiting for an answer from no browser would hang the editor thread.
  (call-next-method display view code :wait (and wait (lem-display-connected-p display))))

;;; --- the client, as served ---

(defun replace-once (text old new)
  (let ((at (search old text)))
    (if at (concatenate 'string (subseq text 0 at) new (subseq text (+ at (length old)))) text)))

(defun patch-lem-client ()
  "Patch lem-server's in-memory copy of its built client (see the header)."
  (let ((entry (assoc "frontend/dist/assets/index.js" lem-server::*dist* :test #'equal)))
    (when entry
      (let* ((text (babel:octets-to-string (cdr entry) :encoding :utf-8))
             (patched (replace-once
                       (replace-once text
                                     "this.input.addEventListener(\"blur\",i=>{this.input.focus()})"
                                     "this.input.addEventListener(\"blur\",i=>{})")
                       "fontName:\"Monospace\",fontSize:18"
                       "fontName:new URLSearchParams(location.search).get(\"font\")||\"Monospace\",fontSize:+(new URLSearchParams(location.search).get(\"size\")||18)")))
        (setf (cdr entry) (babel:string-to-octets patched :encoding :utf-8))
        (string/= text patched)))))

(patch-lem-client)

(defun lem-display-clack-handler (env)
  "Guard, then serve, every request to the Lem display server (see the
header).  NIL lets a websocket upgrade through to Lem."
  (let* ((headers (getf env :headers))
         (host (and headers (gethash "host" headers)))
         (origin (and headers (gethash "origin" headers)))
         (path (or (getf env :path-info) "/")))
    (cond ((not (loopback-host-p host))
           '(403 (:content-type "text/plain") ("Forbidden: Lem only answers on 127.0.0.1.")))
          ((wsd:websocket-p env)
           (if (and origin (string= origin (format nil "http://~a" host)))
               nil
               '(403 (:content-type "text/plain") ("Forbidden: not from the Lem page."))))
          ((or (string= path "/") (uiop:string-prefix-p "/assets/" path))
           (lem-server::clack-handler env))
          (t '(404 (:content-type "text/plain") ("Not found."))))))

;;; --- the server, started when the page first asks for it ---

(defvar *lem-display-port* nil)
(defvar *lem-display-lock* (bt:make-lock "lem-display"))

(defun free-local-port ()
  (let ((socket (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (prog1 (usocket:get-local-port socket) (usocket:socket-close socket))))

(defun lem-display-redraw-all ()
  (lem:send-event (lambda ()
                    (lem-core::adjust-all-window-size)
                    (lem:redraw-display :force t))))

(defun lem-display-start ()
  "Start the display's websocket server (once) and return its port."
  (unless (lem-host-available-p)
    (error 'lem-host-unavailable :reason *lem-host-problem*))
  (bt:with-lock-held (*lem-display-lock*)
    (or *lem-display-port*
        (let* ((display (lem:implementation))
               (server (lem-server::jsonrpc-server display))
               (port (free-local-port)))
          (unless (typep display 'lem-host-display)
            (error "Lem is not running with cl-agent's display."))
          (jsonrpc:expose server "login" (lem-server::login display #'lem-display-redraw-all))
          (jsonrpc:expose server "input" (lambda (args) (lem-server::input-callback display args)))
          (jsonrpc:expose server "redraw" 'lem-server::redraw)
          (jsonrpc:expose server "got-clipboard-text" 'lem-server::got-clipboard-text)
          (jsonrpc:expose server "invoke" 'lem-server::invoke)
          (bt:make-thread
           (lambda ()
             (let ((*error-output* (make-broadcast-stream)) (*trace-output* (make-broadcast-stream)))
               (jsonrpc:server-listen server :mode :websocket :port port :host "127.0.0.1"
                                             :debug nil :silent t :clack-handler 'lem-display-clack-handler)))
           :name "lem-display-server")
          ;; Answering yet?
          (loop repeat 100
                until (ignore-errors (usocket:socket-close (usocket:socket-connect "127.0.0.1" port)) t)
                do (sleep 0.05))
          (setf *lem-display-port* port)))))

(defun lem-display-url (&key (font "Monospace") (size 14))
  "The URL of the Lem display page, starting its server if need be."
  (format nil "http://127.0.0.1:~d/?font=~a&size=~d" (lem-display-start)
          (quri:url-encode font) size))

(defun lem-visit (path &key line)
  "Show PATH in the Lem display's current window (as C-x C-f), at LINE."
  (let ((opened nil))
    (prog1 (lem-call
            (lambda ()
              (let ((full (expand-user-path path)))
                (multiple-value-bind (buffer new-p) (lem:find-file-buffer full)
                  (setf opened (and new-p (lem:buffer-filename buffer)))
                  (lem:switch-to-buffer buffer)
                  (when line
                    (lem:move-to-line (lem:buffer-point buffer) line)
                    (lem:line-start (lem:buffer-point buffer)))
                  (lem:redraw-display :force t)
                  (editor-buffer-json buffer)))))
      (when opened
        (run-hook :file-opened opened)
        (editor-publish "file-buffers" (jobj "opened" opened))))))
