;;;; workdir.lisp -- the working directory, per session.
;;;;
;;;; Several live sessions (docs/live-sessions.md) work in different
;;;; repositories at once, so "the working directory" is the current
;;;; session's: CURRENT-DIRECTORY is what tools, the editor, memory, the
;;;; logic index, environments, LSP and skills mean by it.  The first session
;;;; has none of its own and follows the process's (/cd changes it, as it
;;;; always did); one started beside it keeps its own, and its turns -- and
;;;; web requests made for it -- bind *DEFAULT-PATHNAME-DEFAULTS* to it, so
;;;; relative pathnames resolve there too.  The process's directory is never
;;;; changed for such a session: it belongs to every session.

(in-package :cl-agent)

(defvar *current-session*)                  ; repl.lisp

(defgeneric session-working-directory (session)
  (:documentation "SESSION's own working directory, or NIL to follow the process's.")
  (:method (session) (declare (ignore session)) nil))

(defun current-directory ()
  "The working directory of the session this thread serves."
  (let ((session (and (boundp '*current-session*) *current-session*)))
    (or (and session (session-working-directory session))
        (uiop:getcwd))))

(defmacro with-session-directory ((session) &body body)
  "Run BODY with relative pathnames resolving in SESSION's own directory,
when it has one."
  (let ((directory (gensym "DIRECTORY")))
    `(let* ((,directory (and ,session (session-working-directory ,session)))
            (*default-pathname-defaults* (or ,directory *default-pathname-defaults*)))
       ,@body)))
