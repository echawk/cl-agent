;;;; lem/files.lisp -- the user's files, edited through the hosted Lem: what
;;;; C-x C-f, dired and C-x C-s do in Lem, for the web UI's Code tab.
;;;;
;;;; A file is opened with Lem's own FIND-FILE-BUFFER, so Lem detects its mode
;;;; (extension, #! line, -*- mode -*- line), reads it in its own encoding and
;;;; line endings, and runs *FIND-FILE-HOOK* and the mode's hooks -- the
;;;; user's init file's included.  The page edits a copy of the text and syncs
;;;; it into that Lem buffer (EDITOR-UPDATE-FILE), which is highlighted by the
;;;; buffer's own mode; nothing reaches the disk until C-x C-s, which is Lem's
;;;; SAVE-BUFFER (its newline-at-EOF and trailing-whitespace settings, its
;;;; before-/after-save hooks), as in Emacs.
;;;;
;;;; Directory listings are Lem's LIST-DIRECTORY (as its directory-mode, i.e.
;;;; dired, lists), and the find-file prompt completes with Lem's
;;;; COMPLETION-FILE.  Lem's own lsp-mode is kept off: cl-agent's language
;;;; servers (lsp.lisp) answer for these files too, and see unsaved text.
;;;;
;;;; Hook points (hooks.lisp): :working-directory-changed, :file-opened,
;;;; :before-file-save (chain), :after-file-save, :file-written, :file-closed.
;;;; Every change is published to open pages: "file-buffer", "file-buffers",
;;;; "cwd".

(in-package :cl-agent)

;; Lem's lsp-mode would start a second language server for every file
;; opened; cl-agent's (lsp.lisp) already serves them.
(setf lem-lsp-mode/lsp-mode::*disable* t)

(defun editor-publish (type payload)
  (when (and (boundp '*web-frontends*) *web-frontends*) (web-ui-broadcast type payload)))

;;; --- the working directory ---

(defun expand-user-path (path &optional (directory (current-directory)))
  "PATH (\"~/src\", \"../x\", \"/abs\") as an absolute native namestring,
relative to DIRECTORY, the way Lem's EXPAND-FILE-NAME reads it."
  (unless (and (stringp path) (plusp (length (string-trim " " path))))
    (error "Give a path."))
  (let ((path (string-trim " " path)))
    ;; Lem's EXPAND-FILE-NAME reads "~/" as home, but "~" alone as a name.
    (lem:expand-file-name (if (string= path "~") "~/" path)
                          (uiop:native-namestring (uiop:ensure-directory-pathname directory)))))

(defun set-working-directory (directory &key (by "user"))
  "Make DIRECTORY the working directory: the shell tools, file tools, LSP
roots and project skills all follow it.  Runs :WORKING-DIRECTORY-CHANGED
with the old and new directories, and tells open pages.  Returns the new
directory."
  (let* ((session (and (boundp '*current-session*) *current-session*))
         (own (and session (session-working-directory session)))
         (old (current-directory))
         (new (uiop:directory-exists-p (expand-user-path directory))))
    (unless new (error "There is no directory ~a." directory))
    (setf new (truename new))
    (unless (uiop:pathname-equal old new)
      (if own
          ;; A session with a directory of its own (workdir.lisp): just its.
          (setf (session-working-directory session) new)
          (uiop:chdir new))
      (setf *default-pathname-defaults* new)
      (run-hook :working-directory-changed old new)
      (let ((payload (jobj "cwd" (uiop:native-namestring new) "by" by)))
        (if (and own (typep (session-frontend session) 'web-frontend))
            (web-frontend-event (session-frontend session) "cwd" payload)   ; its pages only
            (editor-publish "cwd" payload))))
    new))

;;; --- directories, as Lem's directory-mode lists them ---

(defparameter *directory-sort-methods* '(("name" . :pathname) ("mtime" . :mtime) ("size" . :size)))

(defun directory-entry-json (pathname directory)
  (let* ((directory-p (uiop:directory-pathname-p pathname))
         (size (and (not directory-p) (ignore-errors (lem:file-size pathname)))))
    (jobj "name" (let ((name (enough-namestring pathname directory)))
                   (if directory-p (string-right-trim "/" name) name))
          "path" (uiop:native-namestring pathname)
          "directory" (and directory-p t)
          "size" (json-or-null size)
          "sizeText" (if size (lem/directory-mode/internal::human-readable-file-size size) "")
          "modified" (json-or-null (ignore-errors (file-write-date pathname)))
          "link" (and (ignore-errors (lem/directory-mode/file:symbolic-link-p pathname)) t))))

(defun list-directory-json (directory &key (sort "name") hidden)
  "DIRECTORY's entries, directories first, by SORT (name, mtime or size), as
Lem's dired lists them; dot files only with HIDDEN."
  (let ((path (uiop:directory-exists-p (expand-user-path directory))))
    (unless path (error "There is no directory ~a." directory))
    (setf path (truename path))
    (let ((entries (lem:list-directory path :sort-method (or (cdr (assoc sort *directory-sort-methods* :test #'equal))
                                                             :pathname))))
      (jobj "directory" (uiop:native-namestring path)
            "parent" (let ((parent (uiop:pathname-parent-directory-pathname path)))
                       (if (uiop:pathname-equal parent path) :null (uiop:native-namestring parent)))
            "cwd" (uiop:native-namestring (current-directory))
            "sort" sort
            "entries" (jarray (loop for entry in entries
                                    for json = (directory-entry-json entry path)
                                    when (or hidden (not (uiop:string-prefix-p "." (gethash "name" json))))
                                      collect json))))))

(defun abbreviate-home (path)
  "PATH with the home directory written ~/."
  (let ((home (uiop:native-namestring (user-homedir-pathname))))
    (if (uiop:string-prefix-p home path)
        (concatenate 'string "~/" (subseq path (length home)))
        path)))

;;; --- file buffers ---

(defvar *editor-file-versions* (make-hash-table :test 'equal)
  "Lem buffer filename -> the version of its text the page last saw.")

(defun editor-buffer-text (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer) (lem:buffer-end-point buffer)))

(defun editor-file-buffer-p (buffer)
  (and (lem:buffer-filename buffer) (not (eq buffer *lem-highlight-buffer*))))

(defun editor-find-buffer (path)
  "The open Lem buffer visiting PATH, or NIL.  Editor thread.  Lem names a
buffer's file by its true name (symbolic links resolved: /var/... is
/private/var/... on macOS), so PATH matches as written or resolved."
  (lem-before-buffer-access)
  (let* ((full (expand-user-path path))
         (true (ignore-errors (namestring (truename full)))))
    (find-if (lambda (buffer)
               (and (editor-file-buffer-p buffer)
                    (let ((name (lem:buffer-filename buffer)))
                      (or (equal name full) (and true (equal name true))))))
             (lem:buffer-list))))

(defun editor-version (buffer)
  (gethash (lem:buffer-filename buffer) *editor-file-versions* 0))

(defun editor-bump-version (buffer)
  (incf (gethash (lem:buffer-filename buffer) *editor-file-versions* 0)))

(defun editor-buffer-json (buffer &key text)
  "What the page needs about file BUFFER.  Editor thread."
  (let ((path (lem:buffer-filename buffer)))
    (jobj "path" path
          "name" (file-namestring path)
          "directory" (uiop:native-namestring (uiop:pathname-directory-pathname path))
          "mode" (json-or-null (ignore-errors (lem:mode-name (lem:buffer-major-mode buffer))))
          "version" (editor-version buffer)
          "modified" (and (lem:buffer-modified-p buffer) t)
          "readOnly" (and (lem:buffer-read-only-p buffer) t)
          "newFile" (not (probe-file path))
          "changedOnDisk" (and (probe-file path) (ignore-errors (lem:changed-disk-p buffer)) t)
          "text" (if text (editor-buffer-text buffer) :null))))

(defun editor-open-file (path)
  "Visit PATH in Lem, as C-x C-f does (a new file if it does not exist, in
an existing directory), and return the buffer's JOBJ with its text.
Runs :FILE-OPENED the first time."
  (let ((opened nil))
    (prog1 (lem-call
            (lambda ()
              (let ((full (expand-user-path path)))
                (when (uiop:directory-exists-p full)
                  (error "~a is a directory." full))
                (multiple-value-bind (buffer new-p) (lem:find-file-buffer full)
                  (setf opened (and new-p (lem:buffer-filename buffer)))
                  (editor-buffer-json buffer :text t)))))
      (when opened
        (run-hook :file-opened opened)
        (editor-publish "file-buffers" (jobj "opened" opened))))))

(defun require-editor-buffer (path)
  "Editor thread: the buffer visiting PATH, opening it if need be."
  (or (editor-find-buffer path)
      (values (lem:find-file-buffer (expand-user-path path)))))

(defun replace-buffer-text (buffer text)
  "Make BUFFER's text TEXT, changing only the part that differs (so Lem's
undo and marks see an edit, not a rewrite).  Editor thread."
  (let* ((old (editor-buffer-text buffer))
         (limit (min (length old) (length text)))
         (prefix (or (mismatch old text :end1 limit :end2 limit) limit))
         (suffix (loop for i from 0
                       while (and (< i (- limit prefix))
                                  (char= (char old (- (length old) 1 i)) (char text (- (length text) 1 i))))
                       finally (return i))))
    (lem:with-point ((point (lem:buffer-start-point buffer) :left-inserting))
      (lem:character-offset point prefix)
      (lem:delete-character point (- (length old) suffix prefix))
      (lem:insert-string point (subseq text prefix (- (length text) suffix))))))

(defun editor-update-file (path text &key base client)
  "Sync the page's TEXT into the Lem buffer visiting PATH (unsaved, as typing
in Lem would leave it).  BASE is the version the page edited: a buffer
changed since gives (values :CONFLICT JSON-WITH-TEXT).  Otherwise (values
:UPDATED VERSION RUNS MODE), RUNS being the buffer highlighted by its mode."
  (let ((result
          (lem-call
            (lambda ()
              (let ((buffer (require-editor-buffer path)))
                (cond ((and base (/= base (editor-version buffer))
                            (string/= text (editor-buffer-text buffer)))
                       (list :conflict (editor-buffer-json buffer :text t)))
                      (t
                       (when (lem:buffer-read-only-p buffer) (error "~a is read-only." path))
                       (unless (string= text (editor-buffer-text buffer))
                         (replace-buffer-text buffer text)
                         (editor-bump-version buffer))
                       (list :updated (editor-version buffer) (lem-buffer-runs buffer)
                             (ignore-errors (lem:mode-name (lem:buffer-major-mode buffer)))
                             (lem:buffer-filename buffer)
                             (and (lem:buffer-modified-p buffer) t)))))))))
    (when (and (eq (first result) :updated) client)
      (editor-publish "file-buffer" (jobj "path" (fifth result) "version" (second result) "text" text
                                          "modified" (sixth result) "by" "user" "client" client)))
    (values-list (subseq result 0 (min 4 (length result))))))

(defun editor-save-file (path &key force (by "user") client)
  "Save the buffer visiting PATH with Lem's SAVE-BUFFER (C-x C-s).  The
:BEFORE-FILE-SAVE chain sees (:PATH :TEXT) first and may rewrite :TEXT (a
formatter) or signal to refuse.  When the file changed on disk since it
was read, nothing is written unless FORCE: (values :CHANGED-ON-DISK
JSON).  Otherwise (values :SAVED JSON), JSON's text set when saving changed
it (a newline added at the end, trailing spaces removed)."
  (let* ((full (expand-user-path path))
         (refusal (lem-call (lambda ()
                              (let ((buffer (require-editor-buffer full)))
                                (and (not force) (probe-file full) (lem:changed-disk-p buffer)
                                     (list :changed-on-disk (editor-buffer-json buffer)))))))
         (text (and (not refusal) (lem-call (lambda () (editor-buffer-text (require-editor-buffer full))))))
         (chained (and text (getf (run-hook-chain :before-file-save (list :path full :text text)) :text text)))
         (result
           (or refusal
             (lem-call
               (lambda ()
                 (let ((buffer (require-editor-buffer full)))
                   (when (string/= chained (editor-buffer-text buffer))
                     (replace-buffer-text buffer chained)
                     (editor-bump-version buffer))
                   (let ((before (editor-buffer-text buffer)))
                       (ensure-directories-exist full)
                       ;; Lem's newline-at-EOF setting inserts at the buffer's
                       ;; point; the page keeps its own cursor, so put Lem's at
                       ;; the end, where the newline belongs.
                       (lem:buffer-end (lem:buffer-point buffer))
                       (lem:save-buffer buffer t)
                       (let ((changed (string/= before (editor-buffer-text buffer))))
                         (when changed (editor-bump-version buffer))
                         (list :saved (editor-buffer-json buffer :text (or changed (string/= before text))))))))))))
    (when (eq (first result) :saved)
      (run-hook :after-file-save full)
      (run-hook :file-written full by)
      (let ((json (second result)))
        (editor-publish "file-buffer" (jobj "path" full "version" (gethash "version" json)
                                            "text" (gethash "text" json) "modified" nil
                                            "saved" t "by" by "client" (json-or-null client)))))
    (values-list result)))

(defun editor-revert-file (path &key (by "user"))
  "Read the file visiting PATH again from disk, dropping unsaved changes."
  (let ((json (lem-call (lambda ()
                          (let ((buffer (or (editor-find-buffer path) (error "~a is not open." path))))
                            (lem:sync-buffer-with-file-content buffer)
                            (editor-bump-version buffer)
                            (editor-buffer-json buffer :text t))))))
    (editor-publish "file-buffer" (jobj "path" (gethash "path" json) "version" (gethash "version" json)
                                        "text" (gethash "text" json) "modified" nil "reverted" t "by" by))
    json))

(defun editor-close-file (path &key force)
  "Kill the buffer visiting PATH; one with unsaved changes only with FORCE."
  (let ((closed (lem-call (lambda ()
                            (let ((buffer (editor-find-buffer path)))
                              (when buffer
                                (when (and (lem:buffer-modified-p buffer) (not force))
                                  (error "~a has unsaved changes." (lem:buffer-filename buffer)))
                                (prog1 (lem:buffer-filename buffer)
                                  (remhash (lem:buffer-filename buffer) *editor-file-versions*)
                                  (lem:delete-buffer buffer))))))))
    (when closed
      (run-hook :file-closed closed)
      (editor-publish "file-buffers" (jobj "closed" closed)))
    closed))

(defun editor-buffers ()
  "The files open in Lem, as JOBJs without text."
  (if (eq *lem-host-state* :running)
      (lem-call (lambda () (mapcar #'editor-buffer-json (remove-if-not #'editor-file-buffer-p (lem:buffer-list)))))
      nil))

(defun editor-buffer-unsaved-text (path)
  "The text of PATH's open buffer when it has unsaved changes, else NIL."
  (and (eq *lem-host-state* :running)
       (ignore-errors
        (lem-call (lambda ()
                    (let ((buffer (editor-find-buffer path)))
                      (and buffer (lem:buffer-modified-p buffer) (editor-buffer-text buffer))))))))

(defun editor-file-written (path &optional by)
  "A file was written outside the editor (an agent tool, :FILE-WRITTEN): an
open buffer without unsaved changes is read again; one with them is told
the disk changed."
  (when (and (eq *lem-host-state* :running) (not (member by '("user" "agent-editor") :test #'equal)))
    (let ((json (ignore-errors
                 (lem-call (lambda ()
                             (let ((buffer (editor-find-buffer (namestring path))))
                               (when buffer
                                 (if (lem:buffer-modified-p buffer)
                                     (editor-buffer-json buffer)
                                     (progn (lem:sync-buffer-with-file-content buffer)
                                            (editor-bump-version buffer)
                                            (editor-buffer-json buffer :text t))))))))))
      (when json
        (editor-publish "file-buffer"
                        (jobj "path" (gethash "path" json) "version" (gethash "version" json)
                              "text" (gethash "text" json) "modified" (gethash "modified" json)
                              "changedOnDisk" (gethash "modified" json) "by" (or by "agent")))))))

(add-hook :file-written 'refresh-open-editor-buffers #'editor-file-written)

;;; --- creating, renaming and deleting, as dired does ---

(defun editor-create-file (path &key directory)
  "Make the empty file (or, with DIRECTORY, directory) PATH."
  (let ((full (expand-user-path path)))
    (when (probe-file full) (error "~a already exists." full))
    (if directory
        (ensure-directories-exist (uiop:ensure-directory-pathname full))
        (progn (ensure-directories-exist full)
               (with-open-file (out full :direction :output :if-does-not-exist :create))))
    (run-hook :file-written full "user")
    (editor-publish "files-changed" (jobj "directory" (uiop:native-namestring (uiop:pathname-directory-pathname
                                                                                (string-right-trim "/" full)))))
    full))

(defun editor-rename-file (from to)
  "Rename (move) FROM to TO, as dired's R does, keeping an open buffer on it."
  (let ((source (expand-user-path from))
        (target (expand-user-path to (uiop:pathname-directory-pathname (expand-user-path from)))))
    (unless (probe-file source) (error "There is no ~a." source))
    (when (probe-file target) (error "~a already exists." target))
    (ensure-directories-exist target)
    (rename-file source target)
    (when (eq *lem-host-state* :running)
      (lem-call (lambda ()
                  (let ((buffer (editor-find-buffer source)))
                    (when buffer
                      (setf (lem:buffer-filename buffer) (namestring (probe-file target)))))))
      (editor-publish "file-buffers" (jobj "renamed" source "to" target)))
    (editor-publish "files-changed" (jobj "directory" (uiop:native-namestring (uiop:pathname-directory-pathname source))))
    target))

(defun editor-delete-file (path)
  "Delete PATH (a directory only when empty), and close a buffer on it."
  (let* ((full (expand-user-path path))
         (directory (uiop:directory-exists-p full)))
    (unless (probe-file full) (error "There is no ~a." full))
    (ignore-errors (editor-close-file full :force t))
    (if directory
        (uiop:delete-empty-directory directory)
        (delete-file full))
    (editor-publish "files-changed" (jobj "directory" (uiop:native-namestring
                                                        (uiop:pathname-parent-directory-pathname
                                                         (uiop:ensure-directory-pathname full)))))
    full))
