;;;; ui/web/assets.lisp -- the web client as editable, layered data.
;;;;
;;;; The browser client is a handful of ordinary files (static/*.html,
;;;; *.css, *.js, plus EXTENDING.md documenting how to change them).
;;;; Every request resolves an asset PATH such as "app.css" through three
;;;; layers, first match wins:
;;;;
;;;;   1. OVERRIDE  ~/.config/cl-agent/web/PATH -- written by a person or
;;;;                by the agent (the web-ui-write-asset tool).  Persistent,
;;;;                per-user, survives upgrades, removable with
;;;;                web-ui-reset-asset.  Never consulted in safe mode.
;;;;   2. EXTENSION registered in the image by an extension file via
;;;;                REGISTER-WEB-ASSET / DEFINE-WEB-PATCH.  Rolled back with
;;;;                the rest of a failed extension mutation.
;;;;   3. BUILTIN   static/PATH from this source tree, read into the image
;;;;                at load time (so a standalone bin/cl-agent still has it)
;;;;                and re-read whenever the file on disk is newer, so
;;;;                editing the repository's copy live-reloads too.
;;;;
;;;; PATCHES are assets under "patches/": every patches/*.css is linked
;;;; and every patches/*.js loaded as a module after the core client, in
;;;; name order.  They are the low-risk way to restyle or extend the page
;;;; (see static/EXTENDING.md) -- the CSS-and-plugin equivalent of
;;;; hooks.lisp's ADD-HOOK.
;;;;
;;;; SAFE MODE (http://127.0.0.1:PORT/safe) serves BUILTIN assets only, so
;;;; an override that breaks the page can always be undone from the page.
;;;; Overwritten and reset overrides are kept under web/.history/ so
;;;; web-ui-reset-asset can step back one version at a time.

(in-package :cl-agent)

(defstruct web-asset
  path origin owner content source-pathname write-date)

(defvar *web-assets* (make-hash-table :test 'equal)
  "Asset path -> WEB-ASSET for the BUILTIN and EXTENSION layers.")

(defparameter *web-static-directory*
  (asdf:system-relative-pathname "cl-agent" "src/ui/web/static/")
  "The built-in client's directory in a source checkout.")

(defparameter *web-asset-types*
  '(("html" . "text/html; charset=utf-8") ("css" . "text/css; charset=utf-8")
    ("js" . "text/javascript; charset=utf-8") ("mjs" . "text/javascript; charset=utf-8")
    ("json" . "application/json; charset=utf-8") ("svg" . "image/svg+xml; charset=utf-8")
    ("md" . "text/markdown; charset=utf-8") ("txt" . "text/plain; charset=utf-8"))
  "Extensions an asset may have, with the Content-Type each is served as.
Text only: assets are edited as strings by people and by the agent.")

(defun web-asset-extension (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string-downcase (subseq path (1+ dot))))))

(defun web-asset-content-type (path)
  (or (cdr (assoc (web-asset-extension path) *web-asset-types* :test #'string=))
      "text/plain; charset=utf-8"))

(defun valid-web-asset-path-p (path)
  "True for a relative asset path of at most two safe components with a known
text extension: \"app.css\" or \"patches/green-labels.css\", never \"../x\",
\"/etc/x\", or \".history/x\"."
  (and (stringp path)
       (< 0 (length path) 200)
       (let ((parts (uiop:split-string path :separator "/")))
         (and (<= 1 (length parts) 2)
              (every (lambda (part)
                       (and (plusp (length part))
                            (char/= (char part 0) #\.)
                            (every (lambda (c) (or (alphanumericp c) (find c "._-"))) part)))
                     parts)))
       (assoc (web-asset-extension path) *web-asset-types* :test #'string=)
       t))

(defun ensure-valid-web-asset-path (path)
  (unless (valid-web-asset-path-p path)
    (error "Invalid web asset path ~s: use a relative name like \"app.css\" or \"patches/NAME.css\" with one of the extensions ~{.~a~^ ~}."
           path (mapcar #'car *web-asset-types*)))
  path)

(defun web-patch-path-p (path)
  (and (uiop:string-prefix-p "patches/" path)
       (member (web-asset-extension path) '("css" "js") :test #'string=)))

;;; --- Layers 3 and 2: assets held in the image ---

(defun register-web-asset (path content &key (origin :extension) owner source-pathname write-date)
  "Make CONTENT available at /assets/PATH (layer 2 unless ORIGIN is :BUILTIN).
Live pages are told about the change; an override file still takes precedence."
  (ensure-valid-web-asset-path path)
  (setf (gethash path *web-assets*)
        (make-web-asset :path path :origin origin
                        :owner (or owner *registration-owner* "core")
                        :content content :source-pathname source-pathname
                        :write-date write-date))
  (publish-component :web-asset path :owner (or owner *registration-owner* "core")
                     :metadata (list :origin origin :bytes (length content)))
  (web-ui-assets-changed (list path))
  path)

(defun unregister-web-asset (path)
  (when (remhash path *web-assets*)
    (unpublish-component :web-asset path)
    (web-ui-assets-changed (list path))
    t))

(defmacro define-web-patch (name &key css js)
  "Register an in-image patch NAME: CSS (a string) is linked after the core
stylesheets and JS (a string, an ES module) runs after the core client, where
`window.CLAgent` is available.  The extension-file counterpart of writing
patches/NAME.css / patches/NAME.js with the web-ui-write-asset tool.  Re-
evaluating replaces the patch; REMOVE-WEB-PATCH removes it."
  (let ((base (string-downcase (string name))))
    `(progn
       ,@(when css `((register-web-asset ,(format nil "patches/~a.css" base) ,css)))
       ,@(when js `((register-web-asset ,(format nil "patches/~a.js" base) ,js)))
       ,base)))

(defun remove-web-patch (name)
  "Remove both halves of the in-image patch NAME.  Returns true if any existed."
  (let ((base (string-downcase (string name))))
    (let ((css (unregister-web-asset (format nil "patches/~a.css" base)))
          (js (unregister-web-asset (format nil "patches/~a.js" base))))
      (or css js))))

(defun read-text-file (pathname)
  (uiop:read-file-string pathname :external-format :utf-8))

(defun load-builtin-web-assets (&optional (directory *web-static-directory*))
  "Read every static/ file into the image as a BUILTIN asset."
  (dolist (file (and (probe-file directory) (uiop:directory-files directory)))
    (let ((path (file-namestring file)))
      (when (valid-web-asset-path-p path)
        (setf (gethash path *web-assets*)
              (make-web-asset :path path :origin :builtin :owner "core"
                              :content (read-text-file file)
                              :source-pathname file
                              :write-date (file-write-date file)))))))

(load-builtin-web-assets)

(defun refresh-builtin-web-asset (asset)
  "Re-read a BUILTIN asset whose source file changed on disk (development)."
  (let* ((file (web-asset-source-pathname asset))
         (date (and file (ignore-errors (file-write-date file)))))
    (when (and date (not (eql date (web-asset-write-date asset))))
      (ignore-errors
       (setf (web-asset-content asset) (read-text-file file)
             (web-asset-write-date asset) date))))
  asset)

;;; --- Layer 1: override files ---

(defun web-ui-directory () (merge-pathnames "web/" *config-directory*))
(defun web-ui-history-directory () (merge-pathnames ".history/" (web-ui-directory)))

(defun web-asset-override-pathname (path)
  (merge-pathnames (ensure-valid-web-asset-path path) (web-ui-directory)))

(defun web-asset-override-paths ()
  "Relative paths of every valid override file, sorted."
  (let ((root (web-ui-directory)))
    (when (probe-file root)
      (sort (loop for file in (append (uiop:directory-files root)
                                      (loop for sub in (uiop:subdirectories root)
                                            append (uiop:directory-files sub)))
                  for relative = (enough-namestring file root)
                  when (valid-web-asset-path-p relative) collect relative)
            #'string<))))

(defun find-web-asset (path &key safe)
  "Return (values CONTENT LAYER) for PATH, LAYER being :OVERRIDE, :EXTENSION or
:BUILTIN, or NIL if nothing provides it.  SAFE skips everything but BUILTIN."
  (when (valid-web-asset-path-p path)
    (let ((override (and (not safe) (probe-file (web-asset-override-pathname path))))
          (asset (gethash path *web-assets*)))
      (cond (override (values (read-text-file override) :override))
            ((and asset (or (not safe) (eq (web-asset-origin asset) :builtin)))
             (when (eq (web-asset-origin asset) :builtin) (refresh-builtin-web-asset asset))
             (values (web-asset-content asset) (web-asset-origin asset)))
            (t nil)))))

(defun builtin-web-asset-content (path)
  (let ((asset (gethash path *web-assets*)))
    (and asset (eq (web-asset-origin asset) :builtin)
         (web-asset-content (refresh-builtin-web-asset asset)))))

(defun list-web-assets ()
  "Plists (:path :layer :bytes :builtin-p :patch-p) for every effective asset."
  (let ((paths (remove-duplicates
                (append (loop for path being the hash-keys of *web-assets* collect path)
                        (web-asset-override-paths))
                :test #'string=)))
    (loop for path in (sort paths #'string<)
          collect (multiple-value-bind (content layer) (find-web-asset path)
                    (list :path path :layer layer :bytes (length content)
                          :builtin-p (and (builtin-web-asset-content path) t)
                          :patch-p (and (web-patch-path-p path) t)
                          :history (length (web-asset-history path)))))))

(defun web-ui-patch-paths (&key safe)
  "Every patches/*.css|js asset, in name order; none in safe mode."
  (unless safe
    (sort (remove-if-not #'web-patch-path-p
                         (remove-duplicates
                          (append (loop for path being the hash-keys of *web-assets* collect path)
                                  (web-asset-override-paths))
                          :test #'string=))
          #'string<)))

(defun format-web-asset-list ()
  (with-output-to-string (out)
    (format out "Web UI assets (overrides live in ~a):~%" (namestring (web-ui-directory)))
    (dolist (asset (list-web-assets))
      (format out "  ~30a ~9a ~7d bytes~:[~;  patch~]~[~:;  ~:*~d older version~:p~]~%"
              (getf asset :path) (string-downcase (string (getf asset :layer))) (getf asset :bytes)
              (getf asset :patch-p) (getf asset :history)))
    (format out "Open /safe in the browser to bypass every override and patch.")))

;;; --- History: every overwritten or reset override is kept ---

(defun web-asset-history-prefix (path)
  (substitute #\_ #\/ path))

(defun web-asset-history (path)
  "Backups of PATH's previous override contents, newest first."
  (let ((prefix (concatenate 'string (web-asset-history-prefix path) "~")))
    (sort (remove-if-not (lambda (file) (uiop:string-prefix-p prefix (file-namestring file)))
                         (and (probe-file (web-ui-history-directory))
                              (uiop:directory-files (web-ui-history-directory))))
          #'string> :key #'file-namestring)))

(defvar *web-asset-backup-counter* 0)

(defun backup-web-asset-override (path)
  "Copy PATH's current override (if any) into the history directory."
  (let ((current (probe-file (web-asset-override-pathname path))))
    (when current
      (let ((backup (merge-pathnames
                     (format nil "~a~~~d-~4,'0d" (web-asset-history-prefix path)
                             (get-universal-time) (mod (incf *web-asset-backup-counter*) 10000))
                     (web-ui-history-directory))))
        (ensure-directories-exist backup)
        (write-string-atomically backup (read-text-file current))
        backup))))

(defun write-web-asset (path content)
  "Persist CONTENT as the override for PATH, keeping the previous override in
history, and live-reload open pages.  Returns the override pathname."
  (ensure-valid-web-asset-path path)
  (unless (stringp content) (error "Web asset content must be a string."))
  (let ((target (web-asset-override-pathname path)))
    (backup-web-asset-override path)
    (ensure-directories-exist target)
    (write-string-atomically target content)
    (web-ui-assets-changed (list path))
    target))

(defun reset-web-asset (path &key (to :builtin))
  "Undo an override.  TO :BUILTIN deletes it (falling back to the extension or
built-in layer); TO :PREVIOUS restores the newest history backup.  Returns a
short description of what happened."
  (ensure-valid-web-asset-path path)
  (let ((target (web-asset-override-pathname path)))
    (ecase to
      (:builtin
       (cond ((probe-file target)
              (backup-web-asset-override path)
              (delete-file target)
              (web-ui-assets-changed (list path))
              (format nil "Removed the override for ~a; ~a is now served from the ~(~a~) layer."
                      path path (or (nth-value 1 (find-web-asset path)) "(no)")))
             (t (format nil "~a has no override to remove." path))))
      (:previous
       (let ((backup (first (web-asset-history path))))
         (unless backup (error "~a has no earlier version in history." path))
         (ensure-directories-exist target)
         (write-string-atomically target (read-text-file backup))
         (delete-file backup)
         (web-ui-assets-changed (list path))
         (format nil "Restored the previous version of ~a (~d older version~:p remain)."
                 path (length (web-asset-history path))))))))

(defun reset-all-web-assets ()
  "Remove every override (each kept in history).  Returns the paths reset."
  (let ((paths (web-asset-override-paths)))
    (dolist (path paths paths)
      (backup-web-asset-override path)
      (delete-file (web-asset-override-pathname path)))
    (web-ui-assets-changed paths)
    paths))

;;; --- Change detection: tell open pages to restyle or reload ---

(defvar *web-asset-signature* nil
  "Alist (path . write-date) of the files last seen by the watcher.")
(defvar *web-asset-watcher* nil)
(defvar *web-asset-watch-interval* 1)

(defun compute-web-asset-signature ()
  (append
   (loop for asset being the hash-values of *web-assets*
         for file = (web-asset-source-pathname asset)
         when file collect (cons (concatenate 'string "builtin:" (web-asset-path asset))
                                 (ignore-errors (file-write-date file))))
   (loop for path in (web-asset-override-paths)
         collect (cons path (ignore-errors (file-write-date (web-asset-override-pathname path)))))))

(defun web-asset-signature-changes (old new)
  "Asset paths whose entry was added, removed or touched between OLD and NEW."
  (flet ((strip (key) (if (uiop:string-prefix-p "builtin:" key) (subseq key 8) key)))
    (remove-duplicates
     (mapcar #'strip
             (append (loop for entry in new
                           unless (equal entry (assoc (car entry) old :test #'string=))
                             collect (car entry))
                     (loop for entry in old
                           unless (assoc (car entry) new :test #'string=)
                             collect (car entry))))
     :test #'string=)))

(defun web-ui-assets-changed (paths)
  "Notify every live page that PATHS changed and run :WEB-UI-ASSET-CHANGED."
  (setf *web-asset-signature* (ignore-errors (compute-web-asset-signature)))
  (when paths
    (web-ui-broadcast "asset" (jobj "paths" paths
                                    "reload" (and (some (lambda (path)
                                                          (not (string= (or (web-asset-extension path) "") "css")))
                                                        paths)
                                                  t)))
    (dolist (path paths) (run-hook :web-ui-asset-changed path))))

(defun web-asset-watcher-tick ()
  (let* ((new (compute-web-asset-signature))
         (changes (web-asset-signature-changes *web-asset-signature* new)))
    (setf *web-asset-signature* new)
    (when changes (web-ui-assets-changed changes))))

(defun ensure-web-asset-watcher ()
  "Start the polling watcher used while any web page is being served."
  (unless (and *web-asset-watcher* (bt:thread-alive-p *web-asset-watcher*))
    (setf *web-asset-signature* (ignore-errors (compute-web-asset-signature))
          *web-asset-watcher*
          (let ((directory *config-directory*))
            (bt:make-thread
             (lambda ()
               (let ((*config-directory* directory))
                 (loop while *web-frontends*
                       do (sleep *web-asset-watch-interval*)
                          (ignore-errors (web-asset-watcher-tick)))))
             :name "cl-agent web asset watcher")))))
