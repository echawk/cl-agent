;;;; ui/web/file-routes.lisp -- HTTP routes for the Code tab's files: the
;;;; working directory, Lem's directory listing and find-file completion, and
;;;; file buffers in the hosted Lem (lem/files.lisp).
;;;;
;;;;   GET  /api/cwd                       {cwd}
;;;;   POST /api/cwd                       {path}: change the working directory
;;;;   GET  /api/files/list?dir=&sort=&hidden=   a directory, as dired lists it
;;;;   GET  /api/files/complete?input=&dir=      find-file completion (Lem's)
;;;;   GET  /api/files/buffers             the files open in Lem
;;;;   POST /api/files/open                {path}: C-x C-f; the buffer with its text
;;;;   POST /api/files/update              {path, text, base, client?}: sync unsaved
;;;;                                       text into Lem; {version, runs, mode}; 409
;;;;   POST /api/files/save                {path, force?, client?}: C-x C-s; 409 when
;;;;                                       the file changed on disk
;;;;   POST /api/files/revert              {path}: read it again from disk
;;;;   POST /api/files/close               {path, force?}
;;;;   POST /api/files/create              {path, directory?}
;;;;   POST /api/files/rename              {from, to}
;;;;   POST /api/files/delete              {path}
;;;;   POST /api/files/lsp-start           {path}: start its language server; {triggers}
;;;;   POST /api/files/complete-code       {path, text, cursor}: Tab, the unsaved text's
;;;;   POST /api/files/diagnostics         {path, text?}
;;;;   POST /api/files/hover               {path, text?, line, character}
;;;;   GET  /api/lem/display               {url}: Lem's own view of itself (lem/display.lisp)
;;;;   POST /api/lem/visit                 {path, line?}: show a file in Lem's window
;;;;   POST /api/lem/run                   {command}: run a Lem command as M-x would,
;;;;                                       its prompts answered in the Lem view

(in-package :cl-agent)

(defmacro with-file-errors (&body body)
  "BODY's value, or a 400 carrying its error (404 for a missing file)."
  `(handler-case (progn ,@body)
     (error (condition)
       (let ((message (princ-to-string condition)))
         (web-respond (if (or (search "There is no" message) (search "not open" message)) 404 400)
                      (jobj "error" message))))))

(defun body-path (body &optional (key "path"))
  (let ((path (jget body key)))
    (if (and (stringp path) (plusp (length path))) path (error "Give a path."))))

(define-web-route cwd (:path "/api/cwd")
  (jobj "cwd" (uiop:native-namestring (uiop:getcwd))))

(define-web-route cwd-change (:method :post :path "/api/cwd")
  (with-file-errors
    (jobj "cwd" (uiop:native-namestring (set-working-directory (body-path (web-json-body)))))))

(define-web-route files-list (:path "/api/files/list")
  (with-file-errors
    (list-directory-json (or (web-param "dir") (uiop:native-namestring (uiop:getcwd)))
                         :sort (or (web-param "sort") "name")
                         :hidden (equal (web-param "hidden") "1"))))

(define-web-route files-complete (:path "/api/files/complete")
  (completion-result-json
   (find-file-completions (or (web-param "input") "")
                          (or (web-param "dir") (uiop:native-namestring (uiop:getcwd))))))

(define-web-route files-buffers (:path "/api/files/buffers")
  (with-file-errors (jobj "buffers" (jarray (editor-buffers)))))

(defun with-lsp-servers (json)
  (let ((path (gethash "path" json)))
    (setf (gethash "servers" json) (jarray (and (probe-file path) (scratch-buffer-lsp-servers path))))
    json))

(define-web-route files-open (:method :post :path "/api/files/open")
  (with-file-errors (with-lsp-servers (editor-open-file (body-path (web-json-body))))))

(defun utf16-runs (text runs)
  (let ((utf16 (utf16-offsets text)))
    (jarray (mapcar (lambda (run) (destructuring-bind (start end class) run
                                    (list (funcall utf16 start) (funcall utf16 end) class)))
                    runs))))

(define-web-route files-update (:method :post :path "/api/files/update")
  (let* ((body (web-json-body)) (text (jget body "text")))
    (if (not (stringp text))
        (web-respond 400 (jobj "error" "Give the buffer's text."))
        (with-file-errors
          (multiple-value-bind (status version runs mode)
              (editor-update-file (body-path body) text :base (jget body "base") :client (jget body "client"))
            (if (eq status :conflict)
                (web-respond 409 (let ((json version))
                                   (setf (gethash "error" json) "The buffer changed meanwhile.")
                                   json))
                (jobj "version" version "runs" (utf16-runs text runs) "mode" (json-or-null mode))))))))

(define-web-route files-save (:method :post :path "/api/files/save")
  (let ((body (web-json-body)))
    (with-file-errors
      (multiple-value-bind (status json)
          (editor-save-file (body-path body) :force (jget body "force") :client (jget body "client"))
        (if (eq status :changed-on-disk)
            (web-respond 409 (progn (setf (gethash "error" json) "The file changed on disk since it was read.")
                                    json))
            json)))))

(define-web-route files-revert (:method :post :path "/api/files/revert")
  (with-file-errors (editor-revert-file (body-path (web-json-body)))))

(define-web-route files-close (:method :post :path "/api/files/close")
  (let ((body (web-json-body)))
    (with-file-errors (jobj "closed" (json-or-null (editor-close-file (body-path body) :force (jget body "force")))))))

(define-web-route files-create (:method :post :path "/api/files/create")
  (let ((body (web-json-body)))
    (with-file-errors (jobj "path" (editor-create-file (body-path body) :directory (jget body "directory"))))))

(define-web-route files-rename (:method :post :path "/api/files/rename")
  (let ((body (web-json-body)))
    (with-file-errors
      (jobj "path" (uiop:native-namestring (editor-rename-file (body-path body "from") (body-path body "to")))))))

(define-web-route files-delete (:method :post :path "/api/files/delete")
  (with-file-errors (jobj "path" (editor-delete-file (body-path (web-json-body))))))

(define-web-route files-lsp-start (:method :post :path "/api/files/lsp-start")
  (with-file-errors (jobj "triggers" (jarray (path-lsp-start (body-path (web-json-body)))))))

(define-web-route files-complete-code (:method :post :path "/api/files/complete-code")
  (let* ((body (web-json-body)) (text (jget body "text")) (cursor (jget body "cursor")))
    (if (not (and (stringp text) (integerp cursor)))
        (web-respond 400 (jobj "error" "Give the buffer's text and the cursor."))
        (with-file-errors
          (let* ((result (path-complete (expand-user-path (body-path body)) text cursor :unsaved t))
                 (json (completion-result-json result)))
            (setf (gethash "triggers" json) (jarray (getf result :triggers))
                  (gethash "message" json) (json-or-null (getf result :message)))
            json)))))

(define-web-route files-diagnostics (:method :post :path "/api/files/diagnostics")
  (let ((body (web-json-body)))
    (with-file-errors
      (jobj "diagnostics" (jarray (mapcar #'diagnostic-json
                                          (path-diagnostics (expand-user-path (body-path body))
                                                            :text (jget body "text"))))))))

(define-web-route files-hover (:method :post :path "/api/files/hover")
  (let ((body (web-json-body)))
    (with-file-errors
      (jobj "text" (json-or-null (path-hover (expand-user-path (body-path body)) (jget body "line") (jget body "character")
                                             :text (jget body "text")))))))

(define-web-route lem-display (:path "/api/lem/display")
  (with-file-errors
    (jobj "url" (lem-display-url :size (or (ignore-errors (parse-integer (web-param "size"))) 14))
          "connected" (and (lem-display-connected-p) t))))

(define-web-route lem-visit (:method :post :path "/api/lem/visit")
  (let ((body (web-json-body)))
    (with-file-errors (with-lsp-servers (lem-visit (body-path body) :line (jget body "line"))))))

(define-web-route lem-run (:method :post :path "/api/lem/run")
  (let ((name (jget (web-json-body) "command")))
    (with-file-errors
      (unless (and (stringp name) (lem-call (lambda () (lem:find-command name))))
        (error "Lem has no command named ~s." name))
      ;; Its prompts wait for keys from the Lem view: with none open, they
      ;; would hold Lem's editor thread for good.
      (unless (lem-display-connected-p)
        (error "Open the Lem view first: ~a asks its questions there." name))
      ;; Queued, not awaited: its prompts are for the person at the Lem view.
      (lem:send-event (lambda () (lem:call-command (lem:find-command name) nil)))
      (jobj "queued" name))))
