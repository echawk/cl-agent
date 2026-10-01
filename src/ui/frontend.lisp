;;;; ui/frontend.lisp -- the UI extension point: a small protocol any
;;;; "way of talking to the agent" implements, so the chat loop
;;;; (repl.lisp) never hard-codes "print to a terminal". Three
;;;; implementations ship with cl-agent -- cli.lisp (the default,
;;;; today's plain terminal session), tui.lisp (a full-screen terminal
;;;; UI via the `tuition` library), and web.lisp (a browser chat page
;;;; via `hunchentoot`) -- proving the same agent core drives all
;;;; three. This file is deliberately the smallest possible contract
;;;; between them, mirroring providers/provider.lisp's design exactly:
;;;; an abstract base class, a handful of generic functions with
;;;; sensible defaults where one makes sense, and a REGISTER-FRONTEND-
;;;; CLASS + MAKE-FRONTEND registry so a NEW frontend -- written by a
;;;; user, or by the agent itself via write-extension -- is exactly as
;;;; first-class as the three built in ones. Select one with --ui NAME
;;;; / :ui in config.lisp / CL_AGENT_UI.
;;;;
;;;; TO WRITE A NEW FRONTEND (an SDL window, a Discord bot, anything):
;;;; subclass AGENT-FRONTEND, implement at least UI-PROMPT-INPUT (the
;;;; only generic with no default -- everything else degrades to
;;;; printing to *STANDARD-OUTPUT* if you don't override it, which is
;;;; often good enough while you're building something else out), and
;;;; call REGISTER-FRONTEND-CLASS. repl.lisp's RUN-REPL calls only
;;;; these generics -- it has no idea whether it's talking to a
;;;; terminal, a browser, or something not invented yet.

(in-package :cl-agent)

(defclass agent-frontend ()
  ()
  (:documentation "Abstract base class for a UI. Never instantiate
this directly; instantiate a concrete subclass, usually via
MAKE-FRONTEND rather than MAKE-INSTANCE so an unknown :UI name reports
clearly instead of signalling an unbound-class error."))

(defgeneric frontend-display-name (frontend)
  (:documentation "Short human-readable name for banners/errors.")
  (:method ((frontend agent-frontend)) (string-downcase (class-name (class-of frontend)))))

(defgeneric ui-start (frontend)
  (:documentation "Called once, before the first prompt: put the
terminal in raw mode, start an HTTP server thread, whatever this
frontend needs to begin. Default: no-op (plain stdio needs nothing).")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-stop (frontend)
  (:documentation "Called once as the session ends (including on an
error) -- the inverse of UI-START: restore the terminal, stop a
server thread, etc. Default: no-op. Called from UNWIND-PROTECT in
RUN-REPL, so it runs even if the session ends abnormally.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-prompt-input (frontend)
  (:documentation "Block until the next user message is available and
return it as a string, or return NIL to end the session (EOF/quit).
No default method -- every real frontend has an opinion about how
input arrives (read-line, a keypress event, an HTTP POST body via a
queue, ...) and there is no safe generic fallback."))

(defgeneric ui-assistant-text (frontend text)
  (:documentation "Display TEXT, the model's visible reply for this
turn (never NIL -- callers only invoke this when there is text).")
  (:method ((frontend agent-frontend) text) (format t "~&~a~%" text) (force-output)))

(defgeneric ui-tool-started (frontend tool-name arguments)
  (:documentation "A tool call is about to run. ARGUMENTS is the hash
table of parsed call arguments (see tools.lisp).")
  (:method ((frontend agent-frontend) tool-name arguments)
    (ui-system frontend (format nil "~a" (tool-call-summary tool-name arguments)))))

(defgeneric ui-tool-finished (frontend tool-name arguments result)
  (:documentation "A tool call finished; RESULT is the string it
returned (see tools.lisp's CALL-TOOL).")
  (:method ((frontend agent-frontend) tool-name arguments result)
    (declare (ignore tool-name arguments))
    (format t "~a~%" result) (force-output)))

(defgeneric ui-system (frontend text)
  (:documentation "Informational text that isn't part of the model's
reply: startup banners, slash-command output, hook/extension-load
warnings. Kept distinct from UI-ASSISTANT-TEXT so a frontend that
wants to style them differently (a status line vs. the transcript,
say) can.")
  (:method ((frontend agent-frontend) text) (format t "~&~a~%" text) (force-output)))

(defgeneric ui-error (frontend condition)
  (:documentation "A condition the agent loop caught and wants shown
to the user (a provider error, a hook that misbehaved, ...).")
  (:method ((frontend agent-frontend) condition)
    (ui-system frontend (format nil "[error] ~a" condition))))

(defun tool-call-summary (tool-name arguments)
  "A short, generic one-line summary of a tool call, with no
knowledge of any particular tool: if ARGUMENTS has exactly one key,
\"tool-name: that-value\" (e.g. \"shell: echo hi\", \"lookup-cl-spec:
car\"); otherwise \"tool-name {...full JSON...}\". Used by the
default UI-TOOL-STARTED method, and available to any frontend that
wants the same summary."
  (let ((keys (and (hash-table-p arguments) (loop for k being the hash-keys of arguments collect k))))
    (if (= (length keys) 1)
        (format nil "~a: ~a" tool-name (jget arguments (first keys)))
        (format nil "~a ~a" tool-name (json-encode arguments)))))

(defvar *frontend-registry* (make-hash-table :test 'eq)
  "keyword -> class-name, e.g. :cli -> 'cli-frontend. See providers/
registry.lisp's *PROVIDER-REGISTRY* for the identical pattern.")

(defun register-frontend-class (keyword class-name)
  "Make KEYWORD (e.g. :tui) a valid --ui/:ui value, backed by
CLASS-NAME (a symbol naming an AGENT-FRONTEND subclass)."
  (setf (gethash keyword *frontend-registry*) class-name)
  keyword)

(defun list-frontends ()
  "Alist of (keyword . class-name) for every registered frontend."
  (loop for k being the hash-keys of *frontend-registry* using (hash-value v) collect (cons k v)))

(defun make-frontend (keyword &rest initargs)
  "Instantiate the frontend registered under KEYWORD. Signals
FRONTEND-NOT-FOUND for an unregistered KEYWORD."
  (let ((class-name (or (gethash keyword *frontend-registry*)
                         (error 'frontend-not-found :name keyword))))
    (apply #'make-instance class-name initargs)))
