;;;; lem/listener.lisp -- the editor calls the listener: C-c C-a in Lem
;;;; (M-x cl-agent-ask) puts the region -- or, in a Lisp buffer, the
;;;; top-level form at point -- at the main prompt of every open page, with
;;;; where it came from, for you to finish the question.  Nothing is sent:
;;;; the prompt is yours.  (The listener calls the editor with /edit and
;;;; /mx, whose argument completes from Lem's commands below;
;;;; docs/ui-ux-review.md, section 16.)

(in-package :cl-agent)

(defun lem-ask-context (buffer)
  "(values TEXT FIRST-LINE LAST-LINE) for a question about BUFFER: its
region if marked, the top-level form at point in a Lisp buffer, else NIL."
  (flet ((span (start end)
           (values (lem:points-to-string start end)
                   (lem:line-number-at-point start) (lem:line-number-at-point end))))
    (cond ((lem:buffer-mark-p buffer)
           (span (lem:region-beginning buffer) (lem:region-end buffer)))
          ((lem:mode-active-p buffer 'lem-lisp-mode:lisp-mode)
           (lem:with-point ((start (lem:buffer-point buffer)) (end (lem:buffer-point buffer)))
             (lem-lisp-syntax:top-of-defun start)
             (lem:move-point end start)
             (when (lem:scan-lists end 1 0 t)
               (span start end)))))))

(defun lem-ask-prompt-text (buffer)
  "What C-c C-a puts at the main prompt for BUFFER."
  (let ((where (or (lem:buffer-filename buffer) (lem:buffer-name buffer))))
    (multiple-value-bind (text first last) (lem-ask-context buffer)
      (if (and text (plusp (length (string-trim '(#\Space #\Tab #\Newline) text))))
          (format nil "About ~:[lines ~d–~d~;line ~d~*~] of ~a (open in Lem):~%```~%~a~%```~%"
                  (eql first last) first last where (string-right-trim '(#\Newline) text))
          (format nil "About ~a (open in Lem): " where)))))

(lem:define-command cl-agent-ask () ()
  "Put the region (or the Lisp form at point) at cl-agent's main prompt, to ask the agent about it."
  (let ((text (lem-ask-prompt-text (lem:current-buffer))))
    ;; Pages are other code's: publish from the helper thread, not this one.
    (lem-in-background (lambda () (web-ui-command "insert" (jobj "text" text))))
    (lem:message "At the listener's prompt: finish your question there.")))

(lem:define-key lem:*global-keymap* "C-c C-a" 'cl-agent-ask)

;;; /mx's argument completes from the editor's own commands (the page's /mx
;;; runs one in the Code tab): names starting with what you typed, or,
;;; failing that, containing it -- each with its documentation's first line.
(define-command-completer "mx" (context)
  (when (eql (getf context :arg-index) 0)
    (let* ((token (getf context :token))
           ;; Emacs's commands when the Code tab's editor is Emacs (emacs.lisp).
           (all (ignore-errors (if (emacs-is-the-editor-p)
                                   (emacs-command-names token :limit 200)
                                   (second (lem-command-names "" :limit 5000)))))
           (prefixed (completions-matching token all :key #'car :doc #'cdr :kind "lem-command")))
      (or prefixed
          (loop for (name . doc) in all
                when (search (string-downcase token) name)
                  collect (make-completion name :doc doc :kind "lem-command"))))))
