;;;; repl.lisp -- the chat loop (talk to the provider, run tool calls,
;;;; repeat until the model stops asking for tools) and the
;;;; line-oriented REPL around it. Structurally this is class-ref's
;;;; agent-repl.rhm translated to CL, generalized to any LLM-PROVIDER
;;;; and threaded through the hooks in hooks.lisp at every interesting
;;;; point.

(in-package :cl-agent)

(defparameter *default-system-prompt*
  "You are cl-agent, a command-line coding agent running inside a live \
Common Lisp (SBCL) image. Use the shell tool to inspect files, make \
changes, and run tests, the same as any coding agent.

You also have a capability most agents don't: because Lisp is \
image-based, you can modify and extend YOURSELF while running. The \
eval-lisp tool evaluates a form in your own process right now (gone on \
restart -- good for trying an idea or inspecting state like \
(list-tools) or (list-hooks)). The write-extension tool writes a named \
Lisp file to your own ~/.config/cl-agent/extensions/ directory, loads \
it into yourself immediately, and (by default) enables it so it loads \
again on every future start -- this is how you durably add a new \
tool (DEFINE-TOOL), hook into an existing one (ADD-HOOK, see hooks.lisp \
for the full list of hook points), or add a new LLM provider \
(REGISTER-PROVIDER-CLASS). Prefer adding new definitions over \
redefining existing ones from scratch. If the user asks you to improve \
yourself, change how you behave, or add a capability, prefer actually \
doing it with these tools over just explaining how they would do it.

You also have the lookup-cl-spec tool, which looks up a function, \
macro, special operator, variable, constant, or type by name directly \
in the ANSI Common Lisp standard (not your training data). Prefer it \
over guessing when you're not certain of exact argument order, return \
values, or edge-case behavior for a Lisp operator -- especially before \
writing an extension with write-extension, since a wrong signature \
there fails at the model's own expense, not just the user's.

When you finish a task, summarize the result concisely."
  "Default system prompt. Overridable via :SYSTEM-PROMPT in config.lisp
or (setf *default-system-prompt* ...) from an extension.")

(defclass agent-session ()
  ((provider :initarg :provider :accessor session-provider)
   (messages :initarg :messages :initform nil :accessor session-messages)
   (tools :initarg :tools :initform (list-tools) :accessor session-tools)
   (max-tool-iterations :initarg :max-tool-iterations :initform 25
                         :accessor session-max-tool-iterations))
  (:documentation "Holds one conversation's state: which provider it's
talking to, the message history so far, and which tools are on offer.
SESSION-TOOLS is a snapshot taken at construction time (not always
every currently-registered tool) so a hook or extension can curate a
specific session's capabilities independently of the global registry."))

(defun make-session (provider &key system-prompt (tools (list-tools)) max-tool-iterations)
  (make-instance 'agent-session
                  :provider provider
                  :tools tools
                  :messages (list (list :role "system" :content (or system-prompt *default-system-prompt*)))
                  :max-tool-iterations (or max-tool-iterations 25)))

(defun run-tool-call (tool-call)
  "Run one normalized tool-call plist (:id :name :arguments), wrapped
in the :before-tool-call / :after-tool-call chain hooks, and return the
normalized \"tool\" role message to append to the conversation."
  (let* ((ctx (run-hook-chain :before-tool-call
                               (list :tool-name (getf tool-call :name)
                                     :arguments (getf tool-call :arguments))))
         (result (call-tool (getf ctx :tool-name) (getf ctx :arguments)))
         (after (run-hook-chain :after-tool-call
                                 (list :tool-name (getf ctx :tool-name)
                                       :arguments (getf ctx :arguments)
                                       :result result))))
    (list :role "tool" :tool-call-id (getf tool-call :id) :content (getf after :result))))

(defun run-agent-turn (session)
  "Drive SESSION forward: send the current message history to the
provider, print any assistant text, run any requested tool calls and
feed their results back, and repeat until the model replies with no
tool calls (an ordinary turn) or SESSION-MAX-TOOL-ITERATIONS is hit (a
safety valve against an infinite tool-call loop -- the loop is broken
with a synthetic system note appended to the history, not an error, so
the conversation can continue normally afterward)."
  (loop for iteration from 1
        do (let* ((ctx (run-hook-chain :before-request
                                        (list :messages (session-messages session)
                                              :tools (session-tools session))))
                   (assistant-message
                     (handler-case (chat (session-provider session) (getf ctx :messages) (getf ctx :tools))
                       (provider-error (c)
                         (run-hook :on-error c)
                         (format t "~&[error] ~a~%" c)
                         (return-from run-agent-turn nil)))))
              (setf assistant-message (run-hook-chain :after-response assistant-message))
              (setf (session-messages session) (append (session-messages session) (list assistant-message)))
              (when (getf assistant-message :content)
                (format t "~&~a~%" (getf assistant-message :content))
                (force-output))
              (let ((tool-calls (getf assistant-message :tool-calls)))
                (cond
                  ((null tool-calls) (return-from run-agent-turn assistant-message))
                  ((>= iteration (session-max-tool-iterations session))
                   (setf (session-messages session)
                         (append (session-messages session)
                                 (list (list :role "system"
                                             :content (format nil "Stopped after ~d tool-call rounds in this turn; ~
                                                                    continue if you'd like, but check whether you're ~
                                                                    stuck in a loop." iteration)))))
                   (format t "~&[cl-agent] hit max-tool-iterations (~d); pausing this turn.~%" iteration)
                   (return-from run-agent-turn assistant-message))
                  (t (dolist (tc tool-calls)
                       (setf (session-messages session)
                             (append (session-messages session) (list (run-tool-call tc))))))))))
  )

(defparameter *slash-commands* nil
  "Alist of (\"name\" . function), populated by DEFINE-SLASH-COMMAND.
Each function takes (session argument-string) and returns a generalized
boolean: NIL requests the REPL exit, any other value continues it.
Exposed as a list so an extension can add new slash commands; see
DEFINE-SLASH-COMMAND.")

(defmacro define-slash-command (name (session-var arg-var) &body body)
  "Register a /NAME REPL command. BODY runs with SESSION-VAR bound to
the current AGENT-SESSION and ARG-VAR bound to the rest of the input
line after the command name (a string, possibly empty). Return NIL
from BODY to end the REPL (used by /exit); any other value keeps it
running."
  `(setf *slash-commands*
         (cons (cons ,(string-downcase (string name)) (lambda (,session-var ,arg-var) ,@body))
               (remove ,(string-downcase (string name)) *slash-commands* :key #'car :test #'string=))))

(define-slash-command help (session arg)
  (declare (ignore session arg))
  (format t "~&Commands: ~{/~a~^, ~}~%" (sort (mapcar #'car *slash-commands*) #'string<))
  t)

(define-slash-command exit (session arg) (declare (ignore session arg)) nil)
(define-slash-command quit (session arg) (declare (ignore session arg)) nil)

(define-slash-command tools (session arg)
  (declare (ignore arg))
  (dolist (tool (session-tools session)) (format t "~&  ~a - ~a~%" (tool-name tool) (tool-description tool)))
  t)

(define-slash-command call (session arg)
  "Invoke a registered tool directly, bypassing the model -- handy for
trying out or debugging a tool (built-in or just added via
write-extension) without spending a request on it. Usage:
/call TOOL-NAME {\"arg\": \"value\", ...} -- the part after the tool
name is parsed as one JSON object and passed to the tool as-is."
  (declare (ignore session))
  (let* ((space (position #\space arg))
         (name (if space (subseq arg 0 space) arg))
         (json-text (if space (string-left-trim " " (subseq arg space)) "{}")))
    (if (zerop (length name))
        (format t "~&Usage: /call TOOL-NAME {\"arg\": \"value\", ...}~%")
        (handler-case
            (format t "~&~a~%" (call-tool name (json-decode json-text)))
          (error (c) (format t "~&[error] ~a~%" c)))))
  t)

(define-slash-command hooks (session arg)
  (declare (ignore session arg))
  (dolist (entry (list-hooks))
    (format t "~&  ~a: ~{~a~^, ~}~%" (car entry) (or (cdr entry) '("(none)"))))
  t)

(define-slash-command extensions (session arg)
  (declare (ignore session arg))
  (dolist (path (list-extension-files))
    (format t "~&  ~a~:[ (disabled)~;~]~%" (file-namestring path) (extension-enabled-p (file-namestring path))))
  t)

(define-slash-command reload (session arg)
  (declare (ignore arg))
  (multiple-value-bind (loaded failed) (load-enabled-extensions)
    (format t "~&Reloaded ~d extension(s)~:[~;, ~d failed~].~%" (length loaded) failed (length failed)))
  (setf (session-tools session) (list-tools))
  t)

(define-slash-command provider (session arg)
  (declare (ignore arg))
  (format t "~&~a, model ~a~%" (provider-display-name (session-provider session))
          (provider-model (session-provider session)))
  t)

(defun dispatch-slash-command (session line)
  "If LINE starts with /, run the matching command and return its
result (NIL => caller should stop the REPL); otherwise return :NOT-A-COMMAND."
  (if (and (plusp (length line)) (char= (char line 0) #\/))
      (let* ((space (position #\space line))
              (name (string-downcase (subseq line 1 space)))
              (arg (if space (string-left-trim " " (subseq line space)) "")))
        (let ((handler (cdr (assoc name *slash-commands* :test #'string=))))
          (if handler
              (funcall handler session arg)
              (progn (format t "~&Unknown command /~a. Try /help.~%" name) t))))
      :not-a-command))

(defun run-repl (session &key initial-task)
  "The interactive loop: read a line, treat a /command specially,
otherwise append it as a user message and run a turn. Fires
:ON-STARTUP before the first prompt and :ON-SHUTDOWN on the way out
(including via end-of-input / an interrupt reaching here as a
condition)."
  (run-hook :on-startup)
  (unwind-protect
       (progn
         (when (and initial-task (plusp (length initial-task)))
           (setf (session-messages session)
                 (append (session-messages session) (list (list :role "user" :content initial-task))))
           (run-agent-turn session))
         (loop
           (format t "~&> ") (force-output)
           (let ((line (read-line *standard-input* nil nil)))
             (unless line (return))
             (when (plusp (length (string-trim " " line)))
               (let ((result (dispatch-slash-command session line)))
                 (cond
                   ((eq result :not-a-command)
                    (setf (session-messages session)
                          (append (session-messages session) (list (list :role "user" :content line))))
                    (run-agent-turn session))
                   ((null result) (return))))))))
    (run-hook :on-shutdown))
  (values))
