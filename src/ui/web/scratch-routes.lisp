;;;; ui/web/scratch-routes.lisp -- HTTP routes for the Code tab (scratch
;;;; buffers in any language, scratch.lisp) and for Lem's highlighting.
;;;;
;;;;   GET  /api/scratch                   buffers, languages, Lem's status
;;;;   GET  /api/scratch/buffer?name=      {name, text, version, language, path, servers}
;;;;   POST /api/scratch/create            {name, language, text?}
;;;;   POST /api/scratch/save              {name, text, base, client?}; 409 {version, text}
;;;;   POST /api/scratch/delete            {name}
;;;;   POST /api/scratch/diagnostics       {name}: what its language server says
;;;;   POST /api/scratch/hover             {name, line, character} (0-based)
;;;;   POST /api/highlight                 {text, language? | pathname?}: Lem's runs
;;;;
;;;; Highlight runs are [start, end, class] in UTF-16 offsets, the browser's.

(in-package :cl-agent)

(defmacro with-scratch-errors (&body body)
  "BODY's value, or a 400 (404 for a missing buffer) carrying its error."
  `(handler-case (progn ,@body)
     (error (condition)
       (let ((message (princ-to-string condition)))
         (web-respond (if (search "No scratch buffer named" message) 404 400) (jobj "error" message))))))

(defun scratch-buffer-detail-json (name)
  (multiple-value-bind (text version path) (scratch-buffer-contents name)
    (let ((json (scratch-buffer-json path :text text :version version)))
      (setf (gethash "servers" json) (jarray (scratch-buffer-lsp-servers path)))
      json)))

(define-web-route scratch-list (:path "/api/scratch")
  (jobj "buffers" (jarray (scratch-buffers))
        "languages" (jarray (mapcar (lambda (language) (jobj "name" (car language) "extension" (cdr language)))
                                    (scratch-languages)))
        "lem" (let ((status (lem-host-status)))
                (jobj "state" (string-downcase (symbol-name (getf status :state)))
                      "problem" (json-or-null (getf status :problem))))))

(define-web-route scratch-buffer (:path "/api/scratch/buffer")
  (with-scratch-errors (scratch-buffer-detail-json (web-param "name"))))

(define-web-route scratch-create (:method :post :path "/api/scratch/create")
  (let ((body (web-json-body)))
    (with-scratch-errors
      (let ((path (scratch-buffer-create (jget body "name") (jget body "language")
                                         :text (let ((text (jget body "text"))) (if (stringp text) text "")))))
        (scratch-buffer-detail-json (pathname-name path))))))

(define-web-route scratch-save (:method :post :path "/api/scratch/save")
  (let* ((body (web-json-body)) (text (jget body "text")))
    (if (not (stringp text))
        (web-respond 400 (jobj "error" "Give the buffer's text."))
        (with-scratch-errors
          (multiple-value-bind (status version current)
              (scratch-buffer-save (jget body "name") text :base (jget body "base") :client (jget body "client"))
            (if (eq status :conflict)
                (web-respond 409 (jobj "error" "The buffer changed meanwhile." "version" version "text" current))
                (jobj "version" version)))))))

(define-web-route scratch-delete (:method :post :path "/api/scratch/delete")
  (with-scratch-errors
    (scratch-buffer-delete (jget (web-json-body) "name"))
    (jobj "deleted" t)))

(defun diagnostic-json (diagnostic)
  (destructuring-bind (&key server line character end-line end-character severity message source) diagnostic
    (jobj "server" (json-or-null server) "line" (json-or-null line) "character" (json-or-null character)
          "endLine" (json-or-null end-line) "endCharacter" (json-or-null end-character)
          "severity" severity "message" (or message "") "source" (json-or-null source))))

(define-web-route scratch-diagnostics (:method :post :path "/api/scratch/diagnostics")
  (with-scratch-errors
    (let ((diagnostics (scratch-buffer-diagnostics (jget (web-json-body) "name"))))
      (jobj "diagnostics" (jarray (mapcar #'diagnostic-json diagnostics))))))

(define-web-route scratch-hover (:method :post :path "/api/scratch/hover")
  (let ((body (web-json-body)))
    (with-scratch-errors
      (jobj "text" (json-or-null (scratch-buffer-hover (jget body "name") (jget body "line") (jget body "character")))))))

(define-web-route highlight (:method :post :path "/api/highlight")
  (let* ((body (web-json-body))
         (text (jget body "text")))
    (if (not (stringp text))
        (web-respond 400 (jobj "error" "Give the text to highlight."))
        (multiple-value-bind (runs mode)
            (lem-highlight-runs text :language (jget body "language") :pathname (jget body "pathname"))
          (let ((utf16 (utf16-offsets text)))
            (jobj "mode" (json-or-null mode)
                  "runs" (jarray (mapcar (lambda (run)
                                           (destructuring-bind (start end class) run
                                             (list (funcall utf16 start) (funcall utf16 end) class)))
                                         runs))))))))
