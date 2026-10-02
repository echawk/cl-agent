;;;; repl.lisp -- the chat loop (talk to the provider, run tool calls,
;;;; repeat until the model stops asking for tools) and the
;;;; frontend-driven REPL around it. Structurally this is class-ref's
;;;; agent-repl.rhm translated to CL, generalized to any LLM-PROVIDER
;;;; (providers/provider.lisp) and any UI (ui/frontend.lisp), threaded
;;;; through the hooks in hooks.lisp at every interesting point.
;;;;
;;;; This file has no idea whether SESSION-FRONTEND is a terminal, a
;;;; full-screen TUI, or a browser tab -- every place a human needs to
;;;; see something goes through one of the UI-* generic functions (see
;;;; ui/frontend.lisp), and every place input is needed goes through
;;;; UI-PROMPT-INPUT. That is the whole mechanism behind "cl-agent has
;;;; a CLI, a TUI, and a web UI, and they're all the same agent."

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
for the full list of hook points), add a new LLM provider \
(REGISTER-PROVIDER-CLASS), or add a new UI frontend (REGISTER-FRONTEND-\
CLASS, see ui/frontend.lisp) -- if a user asks for the interface to \
look or behave differently and no existing --ui option fits, writing a \
new frontend class is a legitimate way to do that. Prefer adding new \
definitions over redefining existing ones from scratch. If the user \
asks you to improve yourself, change how you behave, or add a \
capability, prefer actually doing it with these tools over just \
explaining how they would do it.

You also have the lookup-cl-spec tool, which looks up a function, \
macro, special operator, variable, constant, or type by name directly \
in the ANSI Common Lisp standard (not your training data). Prefer it \
over guessing when you're not certain of exact argument order, return \
values, or edge-case behavior for a Lisp operator -- especially before \
writing an extension with write-extension, since a wrong signature \
there fails at the model's own expense, not just the user's.

You also have connect-mcp-server/disconnect-mcp-server/list-mcp-servers, \
for attaching to external MCP (Model Context Protocol) servers mid-\
conversation -- do this when the user mentions a tool or data source \
that would be better served by a real MCP server than by you \
improvising with the shell tool.

When you finish a task, summarize the result concisely."
  "Default system prompt. Overridable via :SYSTEM-PROMPT in config.lisp
or (setf *default-system-prompt* ...) from an extension.")

(defclass agent-session ()
  ((provider :initarg :provider :accessor session-provider)
   (frontend :initarg :frontend :accessor session-frontend
             :documentation "The AGENT-FRONTEND driving this session's
I/O (see ui/frontend.lisp). Defaults to a CLI-FRONTEND so existing
code (and tests) that doesn't care about UI can ignore this slot.")
   (messages :initarg :messages :initform nil :accessor session-messages)
   (tools :initarg :tools :initform (list-tools) :accessor session-tools)
   (max-tool-iterations :initarg :max-tool-iterations :initform 25
                         :accessor session-max-tool-iterations)
   (start-time :initform (get-internal-real-time) :accessor session-start-time)
   (raw-stats :initform (list :requests 0 :tool-calls 0 :prompt-tokens 0 :completion-tokens 0 :total-tokens 0)
              :accessor session-raw-stats
              :documentation "Plist of running totals; use SESSION-
STATS-SNAPSHOT, not this directly, for anything display-facing -- it
adds the computed/live fields (:provider :model :elapsed-seconds)."))
  (:documentation "Holds one conversation's state: which provider it's
talking to, which UI is presenting it, the message history so far, and
which tools are on offer. SESSION-TOOLS is a snapshot taken at
construction time (not always every currently-registered tool) so a
hook or extension can curate a specific session's capabilities
independently of the global registry."))

(defun make-session (provider &key frontend system-prompt (tools (list-tools)) max-tool-iterations)
  (make-instance 'agent-session
                  :provider provider
                  :frontend (or frontend (make-frontend :cli))
                  :tools tools
                  :messages (list (list :role "system" :content (or system-prompt *default-system-prompt*)))
                  :max-tool-iterations (or max-tool-iterations 25)))

(defun session-stats-snapshot (session)
  "The plist UI-STATS-UPDATED (ui/frontend.lisp) and the /stats
command display: SESSION-RAW-STATS's running totals, plus :PROVIDER,
:MODEL, and :ELAPSED-SECONDS computed fresh each call."
  (list* :provider (provider-display-name (session-provider session))
         :model (provider-model (session-provider session))
         :elapsed-seconds (round (/ (- (get-internal-real-time) (session-start-time session))
                                    internal-time-units-per-second))
         (session-raw-stats session)))

(defun session-note-request (session assistant-message)
  "Fold one CHAT-STREAM/CHAT round trip into SESSION's running stats:
always counts the request; adds token counts only if ASSISTANT-MESSAGE
reported :USAGE (see CHAT's docstring on that commonly being NIL for a
streamed turn -- this makes the totals a lower bound in that case, not
wrong, just incomplete)."
  (let ((stats (session-raw-stats session)) (usage (getf assistant-message :usage)))
    (incf (getf stats :requests))
    (when usage
      (incf (getf stats :prompt-tokens) (or (getf usage :prompt-tokens) 0))
      (incf (getf stats :completion-tokens) (or (getf usage :completion-tokens) 0))
      (incf (getf stats :total-tokens) (or (getf usage :total-tokens) 0)))))

(defun run-tool-call (session tool-call)
  "Run one normalized tool-call plist (:id :name :arguments), wrapped
in the :before-tool-call / :after-tool-call chain hooks and
SESSION-FRONTEND's UI-TOOL-STARTED/UI-TOOL-FINISHED, and return the
normalized \"tool\" role message to append to the conversation."
  (let* ((frontend (session-frontend session))
         (ctx (run-hook-chain :before-tool-call
                               (list :tool-name (getf tool-call :name)
                                     :arguments (getf tool-call :arguments)))))
    (ui-tool-started frontend (getf ctx :tool-name) (getf ctx :arguments))
    (let* ((result (call-tool (getf ctx :tool-name) (getf ctx :arguments)))
           (after (run-hook-chain :after-tool-call
                                   (list :tool-name (getf ctx :tool-name)
                                         :arguments (getf ctx :arguments)
                                         :result result))))
      (ui-tool-finished frontend (getf ctx :tool-name) (getf ctx :arguments) (getf after :result))
      (incf (getf (session-raw-stats session) :tool-calls))
      (ui-stats-updated frontend (session-stats-snapshot session))
      (list :role "tool" :tool-call-id (getf tool-call :id) :content (getf after :result)))))

(defun run-agent-turn (session)
  "Drive SESSION forward: send the current message history to the
provider via CHAT-STREAM (providers/provider.lisp), relaying each
incremental chunk to SESSION-FRONTEND's UI-ASSISTANT-DELTA as it
arrives (bracketed by UI-THINKING-STARTED/STOPPED) and the complete
text to UI-ASSISTANT-TEXT once the response is done, run any requested
tool calls and feed their results back, and repeat until the model
replies with no tool calls (an ordinary turn) or SESSION-MAX-TOOL-
ITERATIONS is hit (a safety valve against an infinite tool-call loop --
the loop is broken with a synthetic system note appended to the
history, not an error, so the conversation can continue normally
afterward). Updates SESSION's running stats (SESSION-STATS-SNAPSHOT)
and fires UI-STATS-UPDATED after every request and tool call."
  (let ((frontend (session-frontend session)))
    (loop for iteration from 1
          do (let* ((ctx (run-hook-chain :before-request
                                          (list :messages (session-messages session)
                                                :tools (session-tools session))))
                     (assistant-message
                       (handler-case
                           (progn
                             (ui-thinking-started frontend)
                             (unwind-protect
                                  (chat-stream (session-provider session) (getf ctx :messages) (getf ctx :tools)
                                               (lambda (chunk) (ui-assistant-delta frontend chunk)))
                               (ui-thinking-stopped frontend)))
                         (provider-error (c)
                           (run-hook :on-error c)
                           (ui-error frontend c)
                           (return-from run-agent-turn nil)))))
                (setf assistant-message (run-hook-chain :after-response assistant-message))
                (setf (session-messages session) (append (session-messages session) (list assistant-message)))
                (session-note-request session assistant-message)
                (when (getf assistant-message :content)
                  (ui-assistant-text frontend (getf assistant-message :content)))
                (ui-stats-updated frontend (session-stats-snapshot session))
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
                     (ui-system frontend (format nil "[cl-agent] hit max-tool-iterations (~d); pausing this turn." iteration))
                     (return-from run-agent-turn assistant-message))
                    (t (dolist (tc tool-calls)
                         (setf (session-messages session)
                               (append (session-messages session) (list (run-tool-call session tc)))))))))))
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
running. Use (ui-system (session-frontend SESSION-VAR) text) for
output, not FORMAT T directly, so the command works under any
frontend, not just the CLI."
  `(setf *slash-commands*
         (cons (cons ,(string-downcase (string name)) (lambda (,session-var ,arg-var) ,@body))
               (remove ,(string-downcase (string name)) *slash-commands* :key #'car :test #'string=))))

(define-slash-command help (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "Commands: ~{/~a~^, ~}" (sort (mapcar #'car *slash-commands*) #'string<)))
  t)

(define-slash-command exit (session arg) (declare (ignore session arg)) nil)
(define-slash-command quit (session arg) (declare (ignore session arg)) nil)

(define-slash-command tools (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "~{~a~^~%~}"
                     (mapcar (lambda (tool) (format nil "~a - ~a" (tool-name tool) (tool-description tool)))
                             (session-tools session))))
  t)

(define-slash-command call (session arg)
  "Invoke a registered tool directly, bypassing the model -- handy for
trying out or debugging a tool (built-in or just added via
write-extension) without spending a request on it. Usage:
/call TOOL-NAME {\"arg\": \"value\", ...} -- the part after the tool
name is parsed as one JSON object and passed to the tool as-is."
  (let* ((frontend (session-frontend session))
         (space (position #\space arg))
         (name (if space (subseq arg 0 space) arg))
         (json-text (if space (string-left-trim " " (subseq arg space)) "{}")))
    (if (zerop (length name))
        (ui-system frontend "Usage: /call TOOL-NAME {\"arg\": \"value\", ...}")
        (handler-case
            (ui-system frontend (call-tool name (json-decode json-text)))
          (error (c) (ui-error frontend c)))))
  t)

(define-slash-command hooks (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "~{~a~^~%~}"
                     (mapcar (lambda (entry) (format nil "~a: ~{~a~^, ~}" (car entry) (or (cdr entry) '("(none)"))))
                             (list-hooks))))
  t)

(define-slash-command extensions (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "~{~a~^~%~}"
                     (mapcar (lambda (path)
                               (format nil "~a~:[ (disabled)~;~]"
                                       (file-namestring path) (extension-enabled-p (file-namestring path))))
                             (list-extension-files))))
  t)

(define-slash-command reload (session arg)
  (declare (ignore arg))
  (multiple-value-bind (loaded failed) (load-enabled-extensions)
    (ui-system (session-frontend session)
               (format nil "Reloaded ~d extension(s)~:[~;, ~d failed~]." (length loaded) failed (length failed))))
  (setf (session-tools session) (list-tools))
  t)

(define-slash-command provider (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "~a, model ~a" (provider-display-name (session-provider session))
                     (provider-model (session-provider session))))
  t)

(define-slash-command stats (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session) (format-stats (session-stats-snapshot session)))
  t)

(define-slash-command mcp (session arg)
  "Usage: /mcp (list connections), /mcp connect NAME cmd arg1 arg2...,
or /mcp disconnect NAME."
  (declare (ignore arg))
  (let ((frontend (session-frontend session))
        (connections (list-mcp-connections)))
    (ui-system frontend
               (if connections
                   (format nil "~{~a~^~%~}"
                           (mapcar (lambda (c) (format nil "~a: ~{~a~^, ~}" (getf c :name) (getf c :tools)))
                                   connections))
                   "No MCP servers currently connected. Use the connect-mcp-server tool, or configure :mcp-servers in config.lisp.")))
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
              (progn (ui-system (session-frontend session) (format nil "Unknown command /~a. Try /help." name)) t))))
      :not-a-command))

(defun run-repl (session &key initial-task)
  "The interactive loop: read a line via SESSION-FRONTEND, treat a
/command specially, otherwise append it as a user message and run a
turn. Fires :ON-STARTUP before the first prompt and :ON-SHUTDOWN on
the way out (including via end-of-input / an interrupt reaching here
as a condition), and brackets the whole session in SESSION-FRONTEND's
UI-START/UI-STOP."
  (let ((frontend (session-frontend session)))
    (ui-start frontend)
    (unwind-protect
         (progn
           (run-hook :on-startup)
           (unwind-protect
                (progn
                  (when (and initial-task (plusp (length initial-task)))
                    (setf (session-messages session)
                          (append (session-messages session) (list (list :role "user" :content initial-task))))
                    (run-agent-turn session))
                  (loop
                    (let ((line (ui-prompt-input frontend)))
                      (unless line (return))
                      (when (plusp (length (string-trim " " line)))
                        (let ((result (dispatch-slash-command session line)))
                          (cond
                            ((eq result :not-a-command)
                             (setf (session-messages session)
                                   (append (session-messages session) (list (list :role "user" :content line))))
                             (run-agent-turn session))
                            ((null result) (return))))))))
             (run-hook :on-shutdown)))
      (ui-stop frontend)))
  (values))
