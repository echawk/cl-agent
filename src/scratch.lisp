;;;; scratch.lisp -- scratch buffers in any language, shared by the user (the
;;;; web UI's Code tab) and the agent (tools/scratch-tool.lisp).
;;;;
;;;; A buffer is a real file, scratch/NAME.EXT in the config directory, so
;;;; its language follows its extension and everything that works on files
;;;; works on it: Lem highlights it by Lem's own mode for the extension
;;;; (lem/highlight.lisp), and the LSP tools and SCRATCH-BUFFER-DIAGNOSTICS
;;;; ask the language server configured for that extension (lsp.lisp).
;;;;
;;;; Saves are versioned like the Lisp tab's scratch buffer: a writer says
;;;; which version it last saw (BASE) and a stale write is refused with the
;;;; current text, so the user's typing and the agent's edits never silently
;;;; overwrite each other.  The agent's writes back up the text they replace
;;;; in scratch/.history/.  Every save is published to open pages as a
;;;; "scratch-buffer" event.

(in-package :cl-agent)

(defvar *scratch-lock* (bt:make-lock "cl-agent-scratch"))
(defvar *scratch-records* (make-hash-table :test 'equal)
  "Pathname namestring -> (TEXT VERSION STAMP) of each buffer read, STAMP
being the file's (WRITE-DATE . SIZE) when it was read.")

;; SCRATCH-DIRECTORY (extensions.lisp) is config/scratch/, where the agent's
;; one-off files also go: those with a buffer name show up here too.
(defun scratch-history-directory () (merge-pathnames "scratch/.history/" *config-directory*))

(defun scratch-name-p (name)
  "Buffer names are file names without an extension: a letter or digit,
then letters, digits, - and _, at most 64."
  (and (stringp name) (<= 1 (length name) 64)
       (alphanumericp (char name 0))
       (every (lambda (c) (or (and (alphanumericp c) (< (char-code c) 128)) (member c '(#\- #\_)))) name)))

(defun scratch-extension-p (extension)
  (and (stringp extension) (<= 1 (length extension) 16)
       (every (lambda (c) (and (< (char-code c) 128) (or (alphanumericp c) (member c '(#\- #\_ #\+))))) extension)))

(defun scratch-buffer-files ()
  (sort (remove-if (lambda (file)
                     (or (null (pathname-type file))
                         (not (scratch-name-p (pathname-name file)))))
                   (ignore-errors (uiop:directory-files (scratch-directory))))
        #'string< :key #'pathname-name))

(defun find-scratch-buffer (name)
  "The file of scratch buffer NAME, or NIL."
  (and (scratch-name-p name)
       (find name (scratch-buffer-files) :key #'pathname-name :test #'string=)))

(defun require-scratch-buffer (name)
  (or (find-scratch-buffer name)
      (error "No scratch buffer named ~s.~@[ There are: ~{~a~^, ~}.~]" name
             (mapcar #'pathname-name (scratch-buffer-files)))))

;;; --- languages ---

(defparameter *scratch-preferred-extensions*
  '(("Lisp" . "lisp") ("C" . "c") ("JavaScript" . "js") ("TypeScript" . "ts") ("Markdown" . "md")
    ("Python" . "py") ("Ruby" . "rb") ("Shell" . "sh") ("posix-shell" . "sh") ("YAML" . "yaml"))
  "A mode's usual extension, where its file types offer several.")

(defun scratch-languages ()
  "The languages a scratch buffer can be in, as (NAME . EXTENSION): every
mode Lem highlights by file type, plus plain text."
  (let ((by-mode (make-hash-table :test 'eq)))
    (ignore-errors
     (when (lem-host-available-p)
       (lem-call
        (lambda ()
          (loop for (type . mode) in lem-core::*file-type-relationals*
                when (and (stringp type) (scratch-extension-p type) (lem-mode-for-pathname (format nil "x.~a" type)))
                  do (push type (gethash mode by-mode)))))))
    (let ((languages
            (loop for mode being the hash-keys of by-mode using (hash-value types)
                  for name = (lem:mode-name mode)
                  for preferred = (cdr (assoc name *scratch-preferred-extensions* :test #'string-equal))
                  collect (cons name (if (member preferred types :test #'string=)
                                         preferred
                                         (first (sort (copy-list types)
                                                      (lambda (a b) (if (= (length a) (length b))
                                                                        (string< a b)
                                                                        (< (length a) (length b)))))))))))
      (append (sort languages #'string-lessp :key #'car) (list (cons "Text" "txt"))))))

(defun scratch-extension-for-language (language)
  "The file extension for LANGUAGE (\"Ruby\", \"c\", \"py\", or an extension)."
  (let ((name (string-trim " " (or language ""))))
    (when (zerop (length name)) (error "Say which language the buffer is in."))
    (or (cdr (assoc name (scratch-languages) :test #'string-equal))
        (let ((mode-name (ignore-errors
                          (and (lem-host-available-p)
                               (lem-call (lambda () (let ((mode (lem-mode-for-language name)))
                                                      (and mode (lem:mode-name mode)))))))))
          (and mode-name (cdr (assoc mode-name (scratch-languages) :test #'string-equal))))
        (let ((extension (string-downcase (string-left-trim "." name))))
          (if (scratch-extension-p extension)
              extension
              (error "Unknown language ~s." language))))))

(defun scratch-buffer-language (path)
  "The name of the mode Lem highlights PATH with, or its extension."
  (or (ignore-errors
       (and (lem-host-available-p)
            (lem-call (lambda () (let ((mode (lem-mode-for-pathname path))) (and mode (lem:mode-name mode)))))))
      (if (equal (pathname-type path) "txt") "Text" (pathname-type path))))

;;; --- contents and saving ---

(defun scratch-file-stamp (path)
  "(WRITE-DATE . SIZE) of PATH, or NIL.  Dates have one-second resolution,
so the size also catches most edits made within the same second."
  (ignore-errors (cons (file-write-date path) (with-open-file (s path) (file-length s)))))

(defun %scratch-record (path)
  "PATH's (TEXT VERSION STAMP), reread when the file changed underneath.
Caller holds *SCRATCH-LOCK*."
  (let* ((key (namestring path))
         (record (gethash key *scratch-records*))
         (stamp (scratch-file-stamp path)))
    (unless (and record (equal (third record) stamp))
      (setf record (list (if stamp (read-text-file path) "")
                         (1+ (if record (second record) 0))
                         stamp)
            (gethash key *scratch-records*) record))
    record))

(defun scratch-buffer-contents (name)
  "(values TEXT VERSION PATHNAME) of scratch buffer NAME."
  (let ((path (require-scratch-buffer name)))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (text version date) (%scratch-record path)
        (declare (ignore date))
        (values text version path)))))

(defun scratch-buffer-json (path &key (text nil text-p) version)
  (jobj "name" (pathname-name path) "extension" (pathname-type path)
        "language" (scratch-buffer-language path)
        "path" (uiop:native-namestring path)
        "size" (or (ignore-errors (with-open-file (s path) (file-length s))) 0)
        "modified" (or (ignore-errors (file-write-date path)) :null)
        "text" (if text-p text :null)
        "version" (or version :null)))

(defun scratch-buffers ()
  "Every scratch buffer as a JOBJ, by name."
  (mapcar #'scratch-buffer-json (scratch-buffer-files)))

(defun scratch-publish (type payload)
  (when (and (boundp '*web-frontends*) *web-frontends*) (web-ui-broadcast type payload)))

(defun scratch-history-files (name)
  "The backups of buffer NAME in scratch/.history/."
  (directory (merge-pathnames (format nil "~a-*.*" name) (scratch-history-directory))))

(defun scratch-backup (path text version)
  (let ((directory (scratch-history-directory)))
    (ensure-directories-exist directory)
    (write-string-atomically
     (merge-pathnames (format nil "~a-~d-v~d.~a" (pathname-name path) (get-universal-time) version (pathname-type path))
                      directory)
     text)
    (let ((old (sort (scratch-history-files (pathname-name path)) #'string> :key #'namestring)))
      (mapc (lambda (file) (ignore-errors (delete-file file))) (nthcdr 20 old)))))

(defun scratch-buffer-save (name text &key base (by "user") client)
  "Replace scratch buffer NAME with TEXT, written by BY (\"user\" or
\"agent\").  BASE is the version the writer last saw: when the buffer has
changed since, nothing is written and the result is (values :CONFLICT
VERSION CURRENT); otherwise (values :SAVED VERSION)."
  (let ((path (require-scratch-buffer name)) (result nil) (published nil))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (current version date) (%scratch-record path)
        (declare (ignore date))
        (cond ((and base (/= base version) (string/= text current))
               (setf result (list :conflict version current)))
              ((string= text current)
               (setf result (list :saved version)))
              (t
               (when (equal by "agent") (scratch-backup path current version))
               (write-string-atomically path text)
               (setf (gethash (namestring path) *scratch-records*) (list text (1+ version) (scratch-file-stamp path))
                     result (list :saved (1+ version))
                     published (jobj "name" name "version" (1+ version) "text" text "by" by
                                     "client" (json-or-null client)))))))
    (when published (scratch-publish "scratch-buffer" published))
    (values-list result)))

(defun scratch-buffer-create (name language &key (text "") (by "user"))
  "Make scratch buffer NAME in LANGUAGE (see SCRATCH-EXTENSION-FOR-LANGUAGE)
holding TEXT, and return its pathname."
  (unless (scratch-name-p name)
    (error "~s is not a usable buffer name: use letters, digits, - and _ (at most 64)." name))
  (when (find-scratch-buffer name)
    (error "There is already a scratch buffer named ~s." name))
  (let ((path (merge-pathnames (make-pathname :name name :type (scratch-extension-for-language language))
                               (scratch-directory))))
    (ensure-directories-exist path)
    (write-string-atomically path (or text ""))
    (scratch-publish "scratch-buffers" (jobj "created" name "by" by))
    path))

(defun scratch-buffer-delete (name)
  "Delete scratch buffer NAME, keeping its text in scratch/.history/."
  (let ((path (require-scratch-buffer name)))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (text version date) (%scratch-record path)
        (declare (ignore date))
        (scratch-backup path text version))
      (delete-file path)
      (remhash (namestring path) *scratch-records*))
    (scratch-publish "scratch-buffers" (jobj "deleted" name))
    t))

;;; --- the language server ---

(defun scratch-buffer-lsp-servers (path)
  "Names of the available language servers configured for PATH's extension."
  (let ((extension (format nil ".~a" (pathname-type path))))
    (loop for server in (ignore-errors (lsp-server-statuses))
          when (and (getf server :available)
                    (member extension (getf server :extensions) :test #'string-equal))
            collect (getf server :name))))

(defun scratch-buffer-diagnostics (name &key (wait-seconds 2))
  "What the configured language servers report for scratch buffer NAME, as
saved: a list of plists (:server :line :character :end-line :end-character
:severity :message :source), lines and characters 0-based.  Signals an
error when no server is configured for its extension."
  (let ((path (require-scratch-buffer name)))
    (unless (scratch-buffer-lsp-servers path)
      (error "No language server is configured for .~a files. Add one to ~a."
             (pathname-type path) (uiop:native-namestring (lsp-configuration-path))))
    (loop for row in (lsp-file-diagnostics (namestring path) :wait-seconds wait-seconds)
          append (lsp-diagnostic-rows row))))

(defun json-path (object &rest keys)
  (dolist (key keys object)
    (setf object (and (hash-table-p object) (gethash key object)))))

(defun lsp-diagnostic-rows (row)
  "Flatten one server's row from LSP-FILE-DIAGNOSTICS, (:SERVER NAME :RESULT
REPORT) or (:SERVER NAME :ERROR CONDITION), into diagnostic plists."
  (let* ((server (getf row :server))
         (items (json-path (getf row :result) "items")))
    (when (getf row :error)
      (return-from lsp-diagnostic-rows
        (list (list :server server :severity "error" :line nil :character nil :end-line nil :end-character nil
                    :message (format nil "The language server failed: ~a" (getf row :error)) :source "cl-agent"))))
    (loop for item across (if (vectorp items) items (coerce (or items nil) 'vector))
          collect (list :server (and server (princ-to-string server))
                        :line (json-path item "range" "start" "line")
                        :character (json-path item "range" "start" "character")
                        :end-line (json-path item "range" "end" "line")
                        :end-character (json-path item "range" "end" "character")
                        :severity (case (json-path item "severity") (1 "error") (2 "warning") (3 "info") (4 "hint") (t "error"))
                        :message (json-path item "message")
                        :source (json-path item "source")))))

(defun scratch-buffer-hover (name line character)
  "The language server's hover text at LINE and CHARACTER (0-based) in
scratch buffer NAME, or NIL."
  (let ((path (require-scratch-buffer name)))
    (unless (scratch-buffer-lsp-servers path)
      (error "No language server is configured for .~a files." (pathname-type path)))
    (let ((texts nil))
      (dolist (row (lsp-query-file (namestring path) "hover" :line line :character character))
        (let ((contents (json-path (getf row :result) "contents")))
          (labels ((collect (value)
                     (cond ((stringp value) (when (plusp (length value)) (push value texts)))
                           ((hash-table-p value) (collect (gethash "value" value)))
                           ((vectorp value) (map nil #'collect value))
                           ((consp value) (mapc #'collect value)))))
            (collect contents))))
      (and texts (format nil "~{~a~^~%~%~}" (nreverse texts))))))
