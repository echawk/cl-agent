;;;; ui/cli.lisp -- the default frontend: today's plain terminal
;;;; session, unchanged from before the UI abstraction existed. Short,
;;;; because AGENT-FRONTEND's own default methods (frontend.lisp)
;;;; already implement "print to *STANDARD-OUTPUT*" -- CLI-FRONTEND
;;;; only has to add the one thing with no sane default: how input
;;;; arrives.

(in-package :cl-agent)

(defclass cli-frontend (agent-frontend) ()
  (:documentation "Reads one line at a time from *STANDARD-INPUT* with
a \"> \" prompt; everything else is AGENT-FRONTEND's default stdout
behavior. See tui.lisp/web.lisp for frontends that override more."))

(defmethod ui-prompt-input ((frontend cli-frontend))
  (format t "~&> ") (force-output)
  (read-line *standard-input* nil nil))

(register-frontend-class :cli 'cli-frontend)
