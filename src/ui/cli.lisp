;;;; ui/cli.lisp -- the default frontend: today's plain terminal
;;;; session.  AGENT-FRONTEND's own default methods (frontend.lisp)
;;;; already implement "print to *STANDARD-OUTPUT*" -- CLI-FRONTEND
;;;; only has to add how input arrives.
;;;;
;;;; On an interactive terminal a reader thread owns stdin, so what you type
;;;; while the agent works is queued (or, with /interrupt, stops the turn)
;;;; instead of waiting for the next prompt.  With piped stdin there is no
;;;; reader thread: lines are consumed one turn at a time, exactly as before.

(in-package :cl-agent)

(defclass cli-frontend (queued-input-mixin)
  ((reader :initform nil :accessor cli-frontend-reader)
   (lines :initform (trivial-channels:make-channel) :reader cli-frontend-lines))
  (:documentation "Reads one line at a time from *STANDARD-INPUT* with
a \"> \" prompt; everything else is AGENT-FRONTEND's default stdout
behavior. See tui.lisp/web.lisp for frontends that override more."))

(defun cli-read-loop (frontend stream)
  "Feed lines from STREAM to FRONTEND until end of input."
  (loop
    (let ((line (read-line stream nil nil)))
      (unless line
        (trivial-channels:sendmsg (cli-frontend-lines frontend) nil)
        (return))
      (multiple-value-bind (status text) (frontend-accept-input frontend line)
        (case status
          (:immediate (trivial-channels:sendmsg (cli-frontend-lines frontend) text))
          (:queued (format t "~&[queued] ~a~%" text) (force-output))
          (:interrupted (format t "~&[interrupting]~%") (force-output)))))))

(defmethod ui-start ((frontend cli-frontend))
  (when (interactive-stream-p *standard-input*)
    (let ((stream *standard-input*))
      (setf (cli-frontend-reader frontend)
            (bordeaux-threads:make-thread (lambda () (cli-read-loop frontend stream))
                                          :name "cl-agent-cli-input")))))

(defmethod ui-stop ((frontend cli-frontend))
  (let ((reader (cli-frontend-reader frontend)))
    (when (and reader (bordeaux-threads:thread-alive-p reader))
      (ignore-errors (bordeaux-threads:destroy-thread reader)))))

(defmethod ui-prompt-input ((frontend cli-frontend))
  (format t "~&> ") (force-output)
  (if (cli-frontend-reader frontend)
      (trivial-channels:recvmsg (cli-frontend-lines frontend))
      (read-line *standard-input* nil nil)))

(register-frontend-class :cli 'cli-frontend)
