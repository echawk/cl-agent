;;;; tools/lisp-scratch-tool.lisp -- the agent's side of the web UI's Lisp
;;;; tab (ui/web/lisp-repl.lisp): the user's scratch buffer and REPL.
;;;;
;;;;   lisp-scratch        read the scratch buffer, or the REPL transcript
;;;;   lisp-scratch-write  replace, edit or append to the scratch buffer
;;;;
;;;; The buffer is ~/.config/cl-agent/repl/scratch.lisp; an open Lisp tab
;;;; shows the agent's writes immediately, and each write keeps the text it
;;;; replaced in repl/.history/.  Evaluating code stays with eval-lisp.

(in-package :cl-agent)

(defun numbered-lines (text &key start end)
  (format nil "~{~a~^~%~}"
          (loop for line in (uiop:split-string text :separator '(#\Newline))
                for number from 1
                when (and (>= number (or start 1)) (or (null end) (<= number end)))
                  collect (format nil "~5d  ~a" number line))))

(define-tool lisp-scratch (args)
    (:description "Read the user's Common Lisp scratch buffer or REPL from the web UI's Lisp tab (a SLY-style REPL on this very image). Use it when the user refers to \"my scratch buffer\", \"the code in my REPL\", or asks you to review, explain or fix Lisp they are working on there. action=\"read\" (default) returns the buffer with line numbers (optionally only start_line..end_line); action=\"transcript\" returns the last `count` REPL interactions: inputs, printed output, values, warnings, and any debugger condition with its restarts and backtrace. Change the buffer with lisp-scratch-write; evaluate code with eval-lisp."
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "read" "transcript"))
                 "start_line" (jobj "type" "integer")
                 "end_line" (jobj "type" "integer")
                 "count" (jobj "type" "integer" "description" "REPL interactions for action=transcript (default 10)."))))
  (if (equal (jget args "action") "transcript")
      (lisp-repl-transcript-text :count (max 1 (min 100 (or (jget args "count") 10))))
      (multiple-value-bind (text version) (lisp-scratch-contents)
        (format nil "Scratch buffer ~a (version ~d, ~d lines):~%~a"
                (namestring (lisp-scratch-pathname)) version
                (1+ (count #\Newline text))
                (numbered-lines text :start (jget args "start_line") :end (jget args "end_line"))))))

(define-tool lisp-scratch-write (args)
    (:description "Change the user's Lisp scratch buffer (the web UI's Lisp tab), only when the user asks you to write or fix code there. Give content (the whole new buffer), or old + new (old must match exactly once unless replace_all), or append (text added at the end). The open Lisp tab updates immediately and the replaced text is backed up, so the user can compare or undo. Nothing is evaluated: suggest the user press C-c C-k (compile and load the buffer) or C-c C-c on a form, or use eval-lisp yourself if they asked you to run it."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "content" (jobj "type" "string" "description" "The complete new buffer.")
                 "old" (jobj "type" "string" "description" "Exact existing text to replace.")
                 "new" (jobj "type" "string" "description" "Replacement for old.")
                 "replace_all" (jobj "type" "boolean")
                 "append" (jobj "type" "string" "description" "Text to add at the end of the buffer."))))
  (handler-case
      (multiple-value-bind (current version) (lisp-scratch-contents)
        (let* ((text (scratch-edited-text current args))
               (imbalance (check-paren-balance text)))
          (multiple-value-bind (status new-version) (lisp-scratch-save text :base version :by "agent")
            (if (eq status :conflict)
                "Not written: the user changed the buffer at the same moment. Read it again and retry."
                (format nil "Updated the scratch buffer (version ~d, ~d lines).~@[~%Warning: ~a~]"
                        new-version (1+ (count #\Newline text))
                        (and imbalance (paren-imbalance-message imbalance)))))))
    (error (condition) (format nil "Not written: ~a" condition))))
