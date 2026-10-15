;;;; lem/lisp-scratch.lisp -- the Lisp tab's scratch buffer, edited in Lem.
;;;;
;;;; The Lisp tab's scratch buffer is repl/scratch.lisp (ui/web/lisp-repl.lisp).
;;;; With the tab's Lem switch on, it is a Lem buffer in Lem's lisp-mode, and
;;;; CL-AGENT-SCRATCH-MODE sends its evaluation keys to the Lisp tab's REPL,
;;;; this image, as the tab's own editor does:
;;;;
;;;;   C-c C-c   compile the top-level form at point
;;;;   C-x C-e   evaluate the form before point
;;;;   C-c C-k   compile and load the whole buffer
;;;;
;;;; Lem's own lisp-mode commands talk to a separate Lisp through micros,
;;;; which this image never starts (lem/host.lisp).  Edits are saved to the
;;;; scratch file as they are made, through LISP-SCRATCH-SAVE, so the agent
;;;; and the simple editor see them; the agent's writes reload the buffer.
;;;;
;;;;   POST /api/lem/lisp-scratch     show the scratch buffer in Lem's window

(in-package :cl-agent)

(lem:define-minor-mode cl-agent-scratch-mode
    (:name "cl-agent" :keymap *cl-agent-scratch-keymap*))

(defun lem-scratch-send (text mode)
  "Evaluate TEXT in the Lisp tab's REPL in MODE; say so in Lem."
  (handler-case (progn (lisp-repl-start text :source "scratch" :mode mode)
                       (lem:message "Sent to the Lisp tab's REPL."))
    (lisp-repl-busy () (lem:message "The Lisp tab's REPL is busy: wait, or C-c C-c in it to interrupt."))
    (error (condition) (lem:message "~a" condition))))

(lem:define-command cl-agent-scratch-compile-form () ()
  "Compile the top-level form at point in cl-agent's image (the Lisp tab's C-c C-c)."
  (lem:with-point ((start (lem:current-point)) (end (lem:current-point)))
    (lem-lisp-syntax:top-of-defun start)
    (lem:move-point end start)
    (if (lem:scan-lists end 1 0 t)
        (lem-scratch-send (lem:points-to-string start end) "compile")
        (lem:message "No form here."))))

(lem:define-command cl-agent-scratch-eval-last () ()
  "Evaluate the form before point in cl-agent's image (the Lisp tab's C-x C-e)."
  (lem:with-point ((start (lem:current-point)) (end (lem:current-point)))
    (if (lem:form-offset start -1)
        (lem-scratch-send (lem:points-to-string start end) "eval")
        (lem:message "No form before point."))))

(lem:define-command cl-agent-scratch-load-buffer () ()
  "Compile and load the scratch buffer in cl-agent's image (the Lisp tab's C-c C-k)."
  (if (lem-scratch-buffer-p (lem:current-buffer))
      (progn (lem-scratch-save-now (lem:current-buffer))
             (lem-scratch-send (lem:buffer-text (lem:current-buffer)) "compile-file"))
      (lem:message "This is not the Lisp tab's scratch buffer.")))

(lem:define-key *cl-agent-scratch-keymap* "C-c C-c" 'cl-agent-scratch-compile-form)
(lem:define-key *cl-agent-scratch-keymap* "C-x C-e" 'cl-agent-scratch-eval-last)
(lem:define-key *cl-agent-scratch-keymap* "C-c C-k" 'cl-agent-scratch-load-buffer)

(defun lem-scratch-buffer-p (buffer)
  "Whether BUFFER visits the scratch file.  Lem names a file by its
truename, so the scratch's path is resolved too (/var is /private/var)."
  (let ((file (lem:buffer-filename buffer))
        (scratch (ignore-errors (probe-file (lisp-scratch-pathname)))))
    (and file scratch (uiop:pathname-equal (uiop:parse-native-namestring file) scratch))))

(defun lem-scratch-save-now (buffer)
  "Save BUFFER's text as the scratch buffer (editor thread): the saving
happens off it, since the scratch's lock and pages are other code's."
  (when (lem:buffer-modified-p buffer)
    (let ((text (lem:buffer-text buffer)))
      (lem:buffer-unmark buffer)
      (lem-in-background (lambda () (lisp-scratch-save text :by "lem"))))))

(defun lem-scratch-after-command (&rest arguments)
  "Lem's post-command hook: the scratch buffer saves as it is edited."
  (declare (ignore arguments))
  (ignore-errors
   (let ((buffer (lem:current-buffer)))
     (when (and (lem:mode-active-p buffer 'cl-agent-scratch-mode) (lem-scratch-buffer-p buffer))
       (lem-scratch-save-now buffer)))))

(lem:add-hook lem:*post-command-hook* 'lem-scratch-after-command)

(defun lem-visit-lisp-scratch ()
  "Show the Lisp tab's scratch buffer in Lem's window, as it is on disk
unless Lem holds edits of it, with CL-AGENT-SCRATCH-MODE on."
  (multiple-value-bind (text version) (lisp-scratch-contents)
    (declare (ignore version))
    (let ((path (lisp-scratch-pathname)))
      (unless (probe-file path)
        (ensure-directories-exist path)
        (write-string-atomically path text))
      (lem-call
       (lambda ()
         (let ((buffer (lem:find-file-buffer (uiop:native-namestring path))))
           (when (and (not (lem:buffer-modified-p buffer)) (string/= (lem:buffer-text buffer) text))
             (lem:sync-buffer-with-file-content buffer))
           (unless (lem:mode-active-p buffer 'cl-agent-scratch-mode)
             (lem:change-buffer-mode buffer 'cl-agent-scratch-mode t))
           (lem:switch-to-buffer buffer)
           (lem:redraw-display :force t)
           (lem-note-shown-buffer)
           (editor-buffer-json buffer)))))))

(define-web-route lem-lisp-scratch (:method :post :path "/api/lem/lisp-scratch")
  (handler-case (lem-visit-lisp-scratch)
    (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition))))))
