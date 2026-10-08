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

(defgeneric ui-show-tool-call-assistant-text-p (frontend)
  (:documentation "Whether assistant narration accompanying a tool call is
shown. Terminal frontends retain it; a final-answer-first frontend can hide
the transient narration while still showing the eventual no-tool completion.")
  (:method ((frontend agent-frontend)) t))

(defgeneric ui-discard-assistant-pending (frontend)
  (:documentation "Discard streamed assistant text when a tool-calling turn
is intentionally not shown by the frontend. Default: no-op.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-agent-activity (frontend label text)
  (:documentation "Record model-provided progress or narration in an optional
activity surface without treating it as a user-facing final response. This is
not hidden chain-of-thought; callers pass only text already returned by the
model. Default: no-op.")
  (:method ((frontend agent-frontend) label text)
    (declare (ignore label text))
    (values)))

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

(defgeneric ui-context-compacted (frontend summary before-tokens after-tokens)
  (:documentation "Report a user-requested context compaction.

The default keeps the generated continuity summary out of an ordinary terminal
transcript and reports only the outcome. Frontends with richer disclosure UI
may retain SUMMARY behind an explicit control.")
  (:method ((frontend agent-frontend) summary before-tokens after-tokens)
    (declare (ignore summary))
    (ui-system frontend
               (format nil "Context compacted on request: conversation estimate ~d -> ~d tokens. Run /context to inspect the next request."
                       before-tokens after-tokens))))

(defgeneric ui-error (frontend condition)
  (:documentation "A condition the agent loop caught and wants shown
to the user (a provider error, a hook that misbehaved, ...).")
  (:method ((frontend agent-frontend) condition)
    (ui-system frontend (format nil "[error] ~a" condition))))

(defgeneric ui-thinking-started (frontend)
  (:documentation "Called at the start of an agent turn, so a frontend
can show an activity indicator while the agent works. The indicator stays
active through tool execution and any follow-up model requests, then is
paired with UI-THINKING-STOPPED when the turn ends, even if it errors.
Default: no-op (the CLI, like before this existed, shows nothing while
waiting -- the final UI-ASSISTANT-TEXT/UI-ASSISTANT-DELTA calls are
enough for it; see this file's header comment on frontends only
needing to override what they actually want to do differently).")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-thinking-stopped (frontend)
  (:documentation "Pairs with UI-THINKING-STARTED when the agent turn
has completed or stopped. Default: no-op.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-planning-started (frontend)
  (:documentation "Called immediately before an orchestration planning request.
This is intentionally distinct from UI-THINKING-STARTED: planning happens
before RUN-AGENT-TURN starts, so a frontend can reassure the user during the
otherwise silent initial planner request. Default: no-op.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-planning-stopped (frontend)
  (:documentation "Pairs with UI-PLANNING-STARTED after the planner returns or
fails. Default: no-op.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-assistant-delta (frontend chunk)
  (:documentation "Called zero or more times as the model's reply
streams in (see CHAT-STREAM, providers/provider.lisp), each CHUNK the
next bit of visible text to show live -- strictly before the final
UI-ASSISTANT-TEXT call for the same turn, which always still fires
with the complete text once the response is done, streamed or not.
Default: no-op, so a frontend that's happy to just show the final
UI-ASSISTANT-TEXT (the CLI) is entirely unaffected by streaming having
been added -- it never has to know the difference between a provider
that streams and one that doesn't.")
  (:method ((frontend agent-frontend) chunk) (declare (ignore chunk)) (values)))

(defgeneric ui-stats-updated (frontend stats)
  (:documentation "Called after each turn with STATS, the plist
SESSION-STATS-SNAPSHOT (repl.lisp) returns:
  (:provider STRING :model STRING :requests N :tool-calls N
   :prompt-tokens N :completion-tokens N :total-tokens N
   :elapsed-seconds N)
Token counts accumulate only from turns where the provider actually
reported usage (see CHAT's docstring on :USAGE commonly being NIL for
a streamed response) -- they are a lower bound, not exact, when any
turn didn't report it. Default: no-op; a frontend with nowhere
sensible to put a stats display (the CLI) can just ignore this.")
  (:method ((frontend agent-frontend) stats) (declare (ignore stats)) (values)))

(defvar *subagent-panel-linger-seconds* 15
  "How long a finished task stays in the live panel before aging out.")

(defgeneric ui-subagent-event (frontend snapshot)
  (:documentation "A subagent task changed state (queued, running, succeeded,
failed, cancelled).  SNAPSHOT is the plist SUBAGENT-TASK-SNAPSHOT (tasks.lisp)
returns.  Default: a one-line status message, so every frontend shows
concurrent agents starting and finishing without any extra work.")
  (:method ((frontend agent-frontend) snapshot)
    (ui-system frontend (format-subagent-event snapshot))))

(defgeneric ui-subagents-updated (frontend snapshots)
  (:documentation "The set of subagents worth showing changed -- a task
started, progressed (new tool call, token count), or finished.  SNAPSHOTS is a
list of task snapshot plists: every live task of this frontend's session plus
recently finished ones (finished tasks carry :FINISHED-AT so a frontend can
age them out).  Frontends with a persistent surface (TUI panel, web pane)
render it; the default is a no-op.")
  (:method ((frontend agent-frontend) snapshots) (declare (ignore snapshots)) (values)))

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

(defun format-stats (stats)
  "One-line human-readable rendering of a SESSION-STATS-SNAPSHOT
(repl.lisp) plist, e.g. \"ollama (qwen2.5:0.5b) | 12s | 3 requests, 2
tool calls | 234 tokens\". Shared by the /stats command and any
frontend that wants the same text for its own stats display (see
ui/tui.lisp/ui/web.lisp, which both use this rather than formatting
STATS themselves)."
  (format nil "~a (~a) | ~ds | ~d request~:p, ~d tool call~:p~@[ | ~d token~:p~]"
          (getf stats :provider) (getf stats :model) (getf stats :elapsed-seconds)
          (getf stats :requests) (getf stats :tool-calls)
          (and (plusp (getf stats :total-tokens 0)) (getf stats :total-tokens))))

;;; ------------------------------------------------------------------
;;; Input while the agent is working: queueing and interrupting
;;;
;;; The core asks a frontend for messages typed during a turn
;;; (UI-POLL-INPUT) and whether the user asked to stop (UI-INTERRUPT-
;;; REQUESTED-P) at safe points: between model requests, between tool calls,
;;; while streaming, and while waiting on long tools.  A frontend that can
;;; accept input while busy mixes in QUEUED-INPUT-MIXIN and routes each
;;; submitted line through FRONTEND-ACCEPT-INPUT.

(defgeneric ui-poll-input (frontend)
  (:documentation "Return, without blocking, the list of message strings the user
queued while the agent was busy, oldest first, and forget them.  Default: NIL.")
  (:method ((frontend agent-frontend)) nil))

(defgeneric ui-interrupt-requested-p (frontend)
  (:documentation "True when the user asked to interrupt the running turn.")
  (:method ((frontend agent-frontend)) nil))

(defgeneric ui-clear-interrupt (frontend)
  (:documentation "Acknowledge an interrupt request.")
  (:method ((frontend agent-frontend)) (values)))

(defgeneric ui-queue-updated (frontend queued)
  (:documentation "The list of queued, not-yet-delivered message strings changed.
Frontends with a persistent surface show it (\"Queued: ...\").  Default: no-op.")
  (:method ((frontend agent-frontend) queued) (declare (ignore queued)) (values)))

(defgeneric ui-input-delivered (frontend text)
  (:documentation "A queued message was handed to the agent; a frontend that did
not echo it when it was typed shows it in the transcript now.  Default: no-op.")
  (:method ((frontend agent-frontend) text) (declare (ignore text)) (values)))

(defclass queued-input-mixin (agent-frontend)
  ((input-queue :initform nil :accessor frontend-input-queue)
   (input-lock :initform (bordeaux-threads:make-lock "cl-agent input queue")
               :reader frontend-input-lock)
   (busy-p :initform nil :accessor frontend-busy-p
           :documentation "True from the start of planning/thinking until the turn ends.")
   (interrupt-flag :initform nil :accessor frontend-interrupt-flag))
  (:documentation "Mixin giving a frontend a thread-safe queue of messages typed
while the agent is busy, plus an interrupt flag."))

(defun parse-interrupt-command (text)
  "Return (values interrupt-p remaining-text) for TEXT, recognising a leading
/interrupt.  \"/interrupt\" alone interrupts; \"/interrupt do X instead\" interrupts
and then sends \"do X instead\"."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline) text)))
    (if (and (>= (length trimmed) 10)
             (string-equal "/interrupt" trimmed :end2 10)
             (or (= (length trimmed) 10)
                 (member (char trimmed 10) '(#\Space #\Tab #\Newline))))
        (values t (string-trim '(#\Space #\Tab #\Newline) (subseq trimmed 10)))
        (values nil trimmed))))

(defun frontend-request-interrupt (frontend)
  "Ask the running turn to stop at its next safe point.  A no-op when idle."
  (when (frontend-busy-p frontend)
    (setf (frontend-interrupt-flag frontend) t)))

(defun frontend-enqueue-input (frontend text)
  (let ((snapshot (bordeaux-threads:with-lock-held ((frontend-input-lock frontend))
                    (setf (frontend-input-queue frontend)
                          (append (frontend-input-queue frontend) (list text)))
                    (copy-list (frontend-input-queue frontend)))))
    (ui-queue-updated frontend snapshot)
    snapshot))

(defun frontend-accept-input (frontend text)
  "Classify a line the user submitted.  Returns (values STATUS TEXT):
  :IMMEDIATE  the agent is idle; the caller delivers TEXT as usual,
  :QUEUED     the agent is busy; TEXT waits for its next safe point,
  :INTERRUPTED  a bare /interrupt stopped the running turn,
  :IGNORED    nothing to do.
\"/interrupt TEXT\" interrupts a busy turn and queues TEXT to run next."
  (multiple-value-bind (interrupt-p remainder) (parse-interrupt-command text)
    (let ((busy (frontend-busy-p frontend)))
      (when (and interrupt-p busy) (frontend-request-interrupt frontend))
      (cond ((zerop (length remainder)) (values (if (and interrupt-p busy) :interrupted :ignored) nil))
            (busy (frontend-enqueue-input frontend remainder) (values :queued remainder))
            (t (values :immediate remainder))))))

(defmethod ui-poll-input ((frontend queued-input-mixin))
  (let ((texts (bordeaux-threads:with-lock-held ((frontend-input-lock frontend))
                 (prog1 (frontend-input-queue frontend)
                   (setf (frontend-input-queue frontend) nil)))))
    (when texts
      (ui-queue-updated frontend nil)
      (dolist (text texts) (ui-input-delivered frontend text)))
    texts))

(defmethod ui-interrupt-requested-p ((frontend queued-input-mixin))
  (and (frontend-interrupt-flag frontend) t))

(defmethod ui-clear-interrupt ((frontend queued-input-mixin))
  (setf (frontend-interrupt-flag frontend) nil))

(defmethod ui-planning-started :before ((frontend queued-input-mixin))
  (setf (frontend-busy-p frontend) t))
(defmethod ui-thinking-started :before ((frontend queued-input-mixin))
  (setf (frontend-busy-p frontend) t))
(defmethod ui-thinking-stopped :after ((frontend queued-input-mixin))
  (setf (frontend-busy-p frontend) nil
        (frontend-interrupt-flag frontend) nil))

(defvar *frontend-registry* (make-hash-table :test 'eq)
  "keyword -> class-name, e.g. :cli -> 'cli-frontend. See providers/
registry.lisp's *PROVIDER-REGISTRY* for the identical pattern.")

(defun register-frontend-class (keyword class-name)
  "Make KEYWORD (e.g. :tui) a valid --ui/:ui value, backed by
CLASS-NAME (a symbol naming an AGENT-FRONTEND subclass)."
  (setf (gethash keyword *frontend-registry*) class-name)
  (publish-component :frontend keyword
                     :metadata (list :class (string-downcase (string class-name))))
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
