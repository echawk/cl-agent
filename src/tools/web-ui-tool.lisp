;;;; tools/web-ui-tool.lisp -- lets the agent read and rewrite its own web
;;;; UI (ui/web/assets.lisp) when the user asks for a change:
;;;;
;;;;   web-ui-assets       guide | list | read     (read-only)
;;;;   web-ui-write-asset  write or edit an override/patch, validated first
;;;;   web-ui-reset-asset  undo: back to built-in, or one version back
;;;;   web-ui-command      drive open pages now: toast, theme, panel, reload
;;;;
;;;; Writes land in ~/.config/cl-agent/web/ and open pages restyle (CSS) or
;;;; reload (anything else) immediately.  The page's /safe address always
;;;; serves the built-in client, so a bad edit is recoverable.  Behavior
;;;; that needs Lisp (a new JSON route, a completion source) belongs in a
;;;; write-extension file instead -- see the guide.

(in-package :cl-agent)

(defvar *node-available* :unknown)

(defun node-available-p ()
  (when (eq *node-available* :unknown)
    (setf *node-available*
          (ignore-errors (uiop:run-program '("node" "--version") :output nil :error-output nil) t)))
  *node-available*)

(defun check-javascript-syntax (source)
  "NIL when SOURCE parses as an ES module (or Node is unavailable to say),
otherwise Node's error message."
  (when (node-available-p)
    (let ((file (uiop:tmpize-pathname (merge-pathnames "cl-agent-web-check.mjs" (uiop:temporary-directory)))))
      (unwind-protect
           (progn
             (write-string-atomically file source)
             (multiple-value-bind (output error-output status)
                 (uiop:run-program (list "node" "--check" (namestring file))
                                   :output :string :error-output :string :ignore-error-status t)
               (declare (ignore output))
               (unless (zerop status)
                 (let ((text error-output))
                   ;; Node reports the resolved path (/private/var/... on macOS).
                   (dolist (name (list (ignore-errors (namestring (truename file))) (namestring file)))
                     (when name (setf text (replace-all-substrings text name "<asset>"))))
                   (string-trim '(#\Newline #\Space) text)))))
        (ignore-errors (delete-file file))))))

(defun check-css-balance (source)
  "NIL when SOURCE's braces balance outside strings and comments."
  (let ((depth 0) (i 0) (n (length source)))
    (loop while (< i n)
          do (let ((c (char source i)))
               (cond ((and (char= c #\/) (< (1+ i) n) (char= (char source (1+ i)) #\*))
                      (setf i (or (search "*/" source :start2 (+ i 2)) n)) (incf i 2))
                     ((member c '(#\" #\'))
                      (setf i (or (position c source :start (1+ i)) n)) (incf i))
                     (t (case c (#\{ (incf depth)) (#\} (decf depth)))
                        (when (minusp depth) (return-from check-css-balance "Unmatched \"}\""))
                        (incf i)))))
    (unless (zerop depth) (format nil "~d unclosed \"{\"" depth))))

(defun web-asset-problems (path content)
  "(values ERROR WARNINGS) for writing CONTENT to PATH."
  (let ((extension (web-asset-extension path)) (warnings nil))
    (when (string= path "index.html")
      (dolist (placeholder '("{{ASSETS}}" "{{PATCH_STYLES}}" "{{PATCH_SCRIPTS}}" "{{BOOT}}"))
        (unless (search placeholder content)
          (push (format nil "index.html no longer contains ~a; the server fills it in, so patches or safe mode may stop working." placeholder)
                warnings))))
    (when (and (member extension '("js" "mjs") :test #'string=) (not (node-available-p)))
      (push "Node.js was not found, so the JavaScript was not syntax-checked; check the page's console." warnings))
    (values (cond ((member extension '("js" "mjs") :test #'string=) (check-javascript-syntax content))
                  ((string= extension "css") (check-css-balance content)))
            (nreverse warnings))))

(defun web-asset-line-range (content start end)
  (let ((lines (uiop:split-string content :separator '(#\Newline))))
    (format nil "~{~a~^~%~}"
            (loop for line in lines for number from 1
                  when (and (>= number (or start 1)) (or (null end) (<= number end)))
                    collect (format nil "~5d  ~a" number line)))))

(define-tool web-ui-assets (args)
    (:description "Inspect cl-agent's own browser UI (the --ui web frontend), which is built from plain files you can change when the user asks for a UI change. action=\"guide\" returns the customization guide (read it before your first UI change): the file layout, the CLAgent JavaScript plugin API, CSS theme tokens, patches, and Lisp-side routes. action=\"list\" shows every asset and which layer serves it (override, extension, builtin). action=\"read\" returns one asset's current content with line numbers (optionally only start_line..end_line)."
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "guide" "list" "read"))
                 "path" (jobj "type" "string" "description" "Asset path for action=read, e.g. \"theme.css\" or \"patches/my-panel.js\".")
                 "start_line" (jobj "type" "integer")
                 "end_line" (jobj "type" "integer"))
           "required" (list "action")))
  (let ((action (jget args "action")) (path (jget args "path")))
    (cond
      ((equal action "guide")
       (or (find-web-asset "EXTENDING.md") "The guide (EXTENDING.md) is missing."))
      ((equal action "list") (format-web-asset-list))
      ((equal action "read")
       (multiple-value-bind (content layer) (and path (find-web-asset path))
         (if content
             (format nil "~a (~(~a~) layer, ~d bytes):~%~a" path layer (length content)
                     (web-asset-line-range content (jget args "start_line") (jget args "end_line")))
             (format nil "No web asset ~s. Use action=\"list\" to see them." path))))
      (t "action must be guide, list or read."))))

(define-tool web-ui-write-asset (args)
    (:description "Change cl-agent's browser UI when the user asks: write a whole asset (content), or replace one exact snippet of it (old + new; old must match exactly once unless replace_all). Writes a persistent override in ~/.config/cl-agent/web/ that takes precedence over the built-in file (the previous version is kept for web-ui-reset-asset). Prefer small, separable changes: restyle via a new patches/NAME.css, add behavior or a panel via patches/NAME.js (loaded automatically after the core client, with window.CLAgent available); edit core files only when a patch cannot do it. JavaScript is syntax-checked with Node and CSS brace-checked before writing; a failing check is not written unless force=true. Open pages update immediately. Read the guide (web-ui-assets action=guide) first."
     :effects '(:self-modify)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "path" (jobj "type" "string" "description" "e.g. \"theme.css\", \"app.js\", or \"patches/compact-mode.css\". New files are allowed.")
                 "content" (jobj "type" "string" "description" "Complete new content (omit when using old/new).")
                 "old" (jobj "type" "string" "description" "Exact existing text to replace.")
                 "new" (jobj "type" "string" "description" "Replacement text for old.")
                 "replace_all" (jobj "type" "boolean")
                 "force" (jobj "type" "boolean" "description" "Write even if the syntax check fails."))
           "required" (list "path")))
  (handler-case
      (let* ((path (ensure-valid-web-asset-path (jget args "path")))
             (old (jget args "old"))
             (content
               (if (stringp old)
                   (let* ((current (or (find-web-asset path)
                                       (error "~a does not exist yet; write it with content first." path)))
                          (count (loop with start = 0 for hit = (search old current :start2 start)
                                       while hit count t do (setf start (+ hit (max 1 (length old)))))))
                     (cond ((zerop count) (error "old was not found in ~a; read it again and copy the text exactly." path))
                           ((and (> count 1) (not (jget args "replace_all")))
                            (error "old occurs ~d times in ~a; include more context or set replace_all." count path)))
                     (replace-all-substrings current old (or (jget args "new") "")))
                   (or (jget args "content") (error "Give content, or old and new.")))))
        (multiple-value-bind (problem warnings) (web-asset-problems path content)
          (if (and problem (not (jget args "force")))
              (format nil "Not written: ~a failed its syntax check:~%~a" path problem)
              (let ((written (write-web-asset path content)))
                (format nil "Wrote ~a (~d bytes) to ~a; open pages ~:[reloaded~;restyled~].~@[~%Syntax check failed but force was set: ~a~]~{~%Warning: ~a~}~:[~;~%It is a patch, so it loads automatically after the core client.~]"
                        path (length content) (namestring written)
                        (string= (web-asset-extension path) "css")
                        problem warnings (web-patch-path-p path))))))
    (error (condition) (format nil "Not written: ~a" condition))))

(define-tool web-ui-reset-asset (args)
    (:description "Undo a web UI change: to=\"builtin\" (default) removes the override for path so the built-in (or extension) version is served again; to=\"previous\" restores the version before the latest write. path=\"all\" removes every override and patch file. Nothing is lost: removed versions stay in the history directory."
     :effects '(:self-modify)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "path" (jobj "type" "string")
                 "to" (jobj "type" "string" "enum" (list "builtin" "previous")))
           "required" (list "path")))
  (handler-case
      (let ((path (jget args "path")))
        (if (equal path "all")
            (format nil "Removed overrides: ~{~a~^, ~}." (or (reset-all-web-assets) '("none")))
            (reset-web-asset path :to (if (equal (jget args "to") "previous") :previous :builtin))))
    (error (condition) (format nil "Not reset: ~a" condition))))

(define-tool web-ui-command (args)
    (:description "Act on every open browser page right now, without changing any file: command \"toast\" {text, color?} shows a notice; \"theme\" {theme: light|dark|toggle}; \"panel\" {id: agents|inspector|activity|tools|ui|<plugin panel id>} opens a side panel; \"view\" {id: listener|lisp} switches the main pane; \"insert\" {text} puts text in the input box; \"reload\" reloads the page; or the name of a command a plugin registered with CLAgent.registerUICommand. Does nothing when no web page is open."
     :effects '(:self-modify)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "command" (jobj "type" "string")
                 "args" (jobj "type" "object" "description" "Command arguments, e.g. {\"text\": \"Done!\"}."))
           "required" (list "command")))
  (let* ((args-object (jget args "args"))
         (pages (web-ui-command (jget args "command") (if (hash-table-p args-object) args-object (jobj)))))
    (if (zerop pages)
        "No web page is open (cl-agent is not running with --ui web), so nothing happened."
        (format nil "Sent ~a to ~d open web frontend~:p." (jget args "command") pages))))
