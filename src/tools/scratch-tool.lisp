;;;; tools/scratch-tool.lisp -- the agent's side of the scratch buffers in
;;;; other languages (scratch.lisp; the web UI's Code tab).
;;;;
;;;;   scratch-buffers       list them, or read one with line numbers
;;;;   scratch-buffer-write  create one, or replace, edit or append to it
;;;;
;;;; Each buffer is a real file, so lsp-diagnostics and lsp-query work on
;;;; its path; the open Code tab shows the agent's writes at once.

(in-package :cl-agent)

(defun scratch-edited-text (current args)
  "The text a scratch write tool's ARGS make of CURRENT: content (the whole
new text), old + new (old must match exactly once unless replace_all), or
append."
  (let ((old (jget args "old")))
    (cond ((stringp old)
           (when (zerop (length old)) (error "old must not be empty."))
           (let ((count (loop with start = 0 for hit = (search old current :start2 start)
                              while hit count t do (setf start (+ hit (length old))))))
             (cond ((zerop count) (error "old was not found; read the buffer again and copy the text exactly."))
                   ((and (> count 1) (not (jget args "replace_all")))
                    (error "old occurs ~d times; include more context or set replace_all." count)))
             (replace-all-substrings current old (or (jget args "new") ""))))
          ((stringp (jget args "append"))
           (format nil "~a~:[~%~;~]~a" current
                   (or (zerop (length current)) (char= (char current (1- (length current))) #\Newline))
                   (jget args "append")))
          ((stringp (jget args "content")) (jget args "content"))
          (t (error "Give content, old and new, or append.")))))

(define-tool scratch-buffers (args)
    (:description "List or read the user's scratch buffers in languages other than Common Lisp (C, Ruby, Python, Rust, Go, shell, ...), from the web UI's Code tab. Use it when the user mentions a scratch buffer, or asks you to review, explain or help with code they are writing there. With no name, lists every buffer with its language and file path. With name, returns that buffer with line numbers (optionally only start_line..end_line). Each buffer is a real file: use lsp-diagnostics or lsp-query on its path to ask the language server. Change buffers with scratch-buffer-write. (The Common Lisp scratch buffer is lisp-scratch.)"
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "name" (jobj "type" "string" "description" "The buffer to read; omit to list them.")
                 "start_line" (jobj "type" "integer")
                 "end_line" (jobj "type" "integer"))))
  (let ((name (jget args "name")))
    (if (and (stringp name) (plusp (length name)))
        (multiple-value-bind (text version path) (scratch-buffer-contents name)
          (format nil "Scratch buffer ~a (~a, version ~d, ~d lines, file ~a):~%~a"
                  name (scratch-buffer-language path) version (1+ (count #\Newline text))
                  (uiop:native-namestring path)
                  (numbered-lines text :start (jget args "start_line") :end (jget args "end_line"))))
        (let ((buffers (scratch-buffer-files)))
          (if buffers
              (format nil "~{~a~^~%~}"
                      (mapcar (lambda (path)
                                (format nil "~a (~a) ~a" (pathname-name path) (scratch-buffer-language path)
                                        (uiop:native-namestring path)))
                              buffers))
              "There are no scratch buffers yet. Make one with scratch-buffer-write (name, language, content).")))))

(define-tool scratch-buffer-write (args)
    (:description "Create or change one of the user's scratch buffers in the web UI's Code tab, only when the user asks you to write, start or fix code there. To create one, give name (letters, digits, - and _), language (\"C\", \"Ruby\", \"Python\", \"rust\", an extension like \"rb\" ...) and content. To change one, give name plus content (the whole new text), or old + new (old must match exactly once unless replace_all), or append. The open Code tab updates immediately and the replaced text is backed up. Nothing is run or compiled; check the result with lsp-diagnostics on the buffer's path when a language server is configured."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "name" (jobj "type" "string")
                 "language" (jobj "type" "string" "description" "Only when creating a buffer.")
                 "content" (jobj "type" "string" "description" "The complete new text.")
                 "old" (jobj "type" "string" "description" "Exact existing text to replace.")
                 "new" (jobj "type" "string" "description" "Replacement for old.")
                 "replace_all" (jobj "type" "boolean")
                 "append" (jobj "type" "string" "description" "Text to add at the end."))
           "required" (list "name")))
  (handler-case
      (let ((name (jget args "name")))
        (if (not (find-scratch-buffer name))
            (let ((language (jget args "language")))
              (unless (stringp language)
                (error "There is no scratch buffer named ~s; to create it, also give language." name))
              (let ((path (scratch-buffer-create name language :text (or (jget args "content") (jget args "append") "")
                                                               :by "agent")))
                (format nil "Created scratch buffer ~a (~a), file ~a."
                        name (scratch-buffer-language path) (uiop:native-namestring path))))
            (multiple-value-bind (current version path) (scratch-buffer-contents name)
              (let ((text (scratch-edited-text current args)))
                (multiple-value-bind (status new-version) (scratch-buffer-save name text :base version :by "agent")
                  (if (eq status :conflict)
                      "Not written: the user changed the buffer at the same moment. Read it again and retry."
                      (format nil "Updated scratch buffer ~a (version ~d, ~d lines, file ~a)."
                              name new-version (1+ (count #\Newline text)) (uiop:native-namestring path))))))))
    (error (condition) (format nil "Not written: ~a" condition))))
