;;;; editor.lisp -- the working directory and the files being edited in the
;;;; Code tab (lem/files.lisp), from the REPL and for the agent:
;;;;
;;;;   /cd DIR, /pwd                 the working directory the tools use
;;;;   set-working-directory         the agent changes it (when asked to)
;;;;   editor-files                  which files the user has open, and their
;;;;                                 unsaved text
;;;;   open-in-editor                show the user a file, at a line

(in-package :cl-agent)

(defun find-file-completions (input directory)
  "Complete find-file INPUT (a path, relative to DIRECTORY) with Lem's
COMPLETION-FILE: a plist like COMPLETE-INPUT's, each candidate the whole
path, directories ending in /."
  (let* ((directory (uiop:native-namestring (uiop:ensure-directory-pathname (expand-user-path directory))))
         (matches (ignore-errors (lem:completion-file input directory)))
         (candidates
           (loop for match in matches
                 for path = (namestring match)
                 for directory-p = (uiop:directory-pathname-p path)
                 collect (make-completion (abbreviate-home path)
                                          :display (let ((name (file-namestring (string-right-trim "/" path))))
                                                     (if directory-p (format nil "~a/" name) name))
                                          :kind (if directory-p "dir" "file")))))
    (list :start 0 :end (length input) :token input
          :candidates (subseq candidates 0 (min (length candidates) *completion-limit*))
          :total (length candidates) :source "paths")))

(define-slash-command cd (session arg)
  "Usage: /cd DIRECTORY (~ and relative paths work) to change the working
directory the shell, file and language-server tools use; /cd alone shows it."
  (let ((frontend (session-frontend session))
        (directory (string-trim " " arg)))
    (handler-case
        (ui-system frontend
                   (if (zerop (length directory))
                       (format nil "Working directory: ~a" (uiop:native-namestring (uiop:getcwd)))
                       (format nil "Working directory: ~a"
                               (uiop:native-namestring (set-working-directory directory)))))
      (error (condition) (ui-system frontend (princ-to-string condition)))))
  t)

(define-slash-command pwd (session arg)
  "Show the working directory."
  (declare (ignore arg))
  (ui-system (session-frontend session) (format nil "Working directory: ~a" (uiop:native-namestring (uiop:getcwd))))
  t)

(define-command-completer "cd" (context)
  (remove-if-not (lambda (candidate) (equal (getf candidate :kind) "dir"))
                 (path-completions (getf context :token))))

(define-tool set-working-directory (args)
    (:description "Change the working directory that shell, file, LSP and project-skill tools use (like cd), only when the user asks to work in another directory or repository. ~ and relative paths work. Returns the new directory."
     :effects '(:write-workspace)
     :parameters (jobj "type" "object"
                       "properties" (jobj "directory" (jobj "type" "string"))
                       "required" (list "directory")))
  (format nil "Working directory is now ~a."
          (uiop:native-namestring (set-working-directory (jget args "directory") :by "agent"))))

(define-tool editor-files (args)
    (:description "See what the user is editing in the web UI's Code tab (files opened through the editor, with C-x C-f). action=\"list\" (default) lists the open files and whether each has unsaved changes; action=\"read\" with path returns that buffer's current text, unsaved edits included, with line numbers -- read-file sees only what is saved on disk. To change a file use write-file or edit-file: an open buffer without unsaved changes reloads, and one with them shows the user that the disk changed."
     :effects '(:read-workspace)
     :parameters (jobj "type" "object"
                       "properties" (jobj "action" (jobj "type" "string" "enum" (list "list" "read"))
                                          "path" (jobj "type" "string"))))
  (if (equal (jget args "action") "read")
      (let* ((path (or (jget args "path") (error "Give the path to read.")))
             (json (lem-call (lambda ()
                               (let ((buffer (or (editor-find-buffer path)
                                                 (error "~a is not open in the editor." path))))
                                 (editor-buffer-json buffer :text t))))))
        (format nil "~a (~a~:[~;, unsaved changes~]):~%~a"
                (gethash "path" json) (or (gethash "mode" json) "text") (gethash "modified" json)
                (numbered-lines (gethash "text" json))))
      (let ((buffers (editor-buffers)))
        (if buffers
            (format nil "~{~a~^~%~}"
                    (mapcar (lambda (json)
                              (format nil "~a (~a)~:[~;, unsaved changes~]~:[~;, changed on disk~]"
                                      (gethash "path" json) (or (gethash "mode" json) "text")
                                      (gethash "modified" json) (gethash "changedOnDisk" json)))
                            buffers))
            (format nil "No files are open in the editor. Working directory: ~a"
                    (uiop:native-namestring (uiop:getcwd)))))))

(define-tool open-in-editor (args)
    (:description "Open a file in the user's Code tab, optionally at a line (1-based), to show them code you are discussing or have just changed. The file is visited through the editor (Lem), as C-x C-f would."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string")
                                          "line" (jobj "type" "integer" "minimum" 1))
                       "required" (list "path")))
  (let* ((json (editor-open-file (jget args "path")))
         (path (gethash "path" json)))
    (web-ui-command "open-file" (jobj "path" path "line" (json-or-null (jget args "line"))))
    (format nil "Opened ~a in the Code tab~@[ at line ~d~]." path (jget args "line"))))
