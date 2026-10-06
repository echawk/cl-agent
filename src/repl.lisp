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
Common Lisp (SBCL) image, with real tool access -- not just the ability \
to describe what a command would do.

Always use a tool instead of telling the user to run something \
themselves or go look something up. You have the same shell access \
they do, including network access (curl, etc.), so if a question is \
about real-world or environment state -- the current directory, a \
file's contents, today's date, the weather, a web page's contents, a \
package's version, anything a shell command would resolve -- resolve \
it yourself and answer with the result, don't describe how they could. \
Only fall back to explaining a manual step if you tried the tool and \
it genuinely failed (e.g. no network, command not found). This does \
NOT mean run a tool for its own sake: a question about yourself (what \
you can do, what tools you have, how you work) is answered directly, \
from this prompt and your own tool list -- that's not something `ls` \
or `pwd` would tell you, so don't call them for it.

Before finishing a task, verify it actually worked rather than \
assuming -- re-read the file you just wrote, re-run the test or \
command that was failing, check the output of the command you just \
ran actually says what you think it says. If it didn't work, keep \
going: fix it and check again, rather than reporting success anyway or \
stopping partway and describing what's left for the user to do \
themselves. Only stop short of a fully working result if you're \
genuinely stuck (e.g. missing information only the user has, or a \
real, not self-imposed, limitation) -- say specifically what's blocking \
you, not just that you stopped.

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

If what's asked for needs its own judgment call or its own creative \
rewrite -- \"rewrite every reply as a poem\", \"refuse to save code \
that has a code smell\", \"translate what you say into French\", \
anything where a hook needs the MODEL'S OWN opinion on some text, not \
just a string operation -- give the hook a SESSION-COMPLETE call: it \
runs a prompt through the current session's own provider as an \
independent completion (its own system prompt, no effect on the real \
conversation) and returns the reply text. A :USER-MESSAGE hook can \
rewrite or expand the user's own message with SESSION-COMPLETE's \
output before you (the main conversation) ever see it -- \"formalize \
whatever I send you\" or \"work out a plan for which tools to use \
before answering\" both mean a :USER-MESSAGE hook (fires once per \
incoming user turn, earliest point in the pipeline, before the system \
prompt or any prior turn is involved -- see hooks.lisp). A \
:AFTER-RESPONSE hook can replace the assistant's own reply with \
SESSION-COMPLETE's output (rewrite-as-poem); a :BEFORE-TOOL-CALL hook \
can call SESSION-COMPLETE to judge something and then (error \"...\") \
to veto the call if it doesn't pass -- the tool never runs and the \
model sees why. See config/example-llm-roundtrip-extension.lisp for \
all three, worked.

You can also ask a separate, independent LLM instance for advice with \
the ask-llm tool. It gets only the prompt and optional system_prompt you \
supply, never this conversation or any tools. Use list-models first when \
you want a particular model, then pass one exact listed ID as ask-llm's \
optional model argument; doing so never changes the main session's model.

Before calling DEFINE-TOOL, ADD-HOOK, REGISTER-PROVIDER-CLASS, or any \
other cl-agent macro/function you haven't just read the definition of \
in this conversation, check its real calling convention with \
lisp-apropos(\"define-tool\") (etc) instead of guessing from memory or \
from what a similar-looking library might do -- a plausible-looking \
but wrong argument order fails write-extension's load step, and \
guessing again from the error message alone tends to compound into \
more guessing rather than converging. One real check up front is \
cheaper than several failed attempts.

You also have the lookup-cl-spec tool, which looks up a function, \
macro, special operator, variable, constant, or type by name directly \
in the ANSI Common Lisp standard (not your training data). Prefer it \
over guessing when you're not certain of exact argument order, return \
values, or edge-case behavior for a Lisp operator -- especially before \
writing an extension with write-extension, since a wrong signature \
there fails at the model's own expense, not just the user's.

Every piece of Common Lisp you generate must make an explicit claim \
about function types: use DEFSTAR forms (DEFUN*, DEFMETHOD*, etc.) or \
a DECLAIM FTYPE before ordinary definitions. Before presenting Common \
Lisp source in a reply, call review-lisp and revise toward the lowest \
practical quality score. A nonzero score is allowed when the task \
genuinely requires it, but compiler failures must be fixed. eval-lisp \
and write-extension perform this review automatically and return \
Mallet, type-claim, and compiler feedback.

To load a Common Lisp dependency, call load-asdf-system with its ASDF \
system name. The image's ASDF is connected to ocicl and will fetch a \
missing system. Never curl an .asd file from the internet.

When asked to explain or use a Common Lisp library, prefer evidence in the \
running image before any network access: use lisp-apropos with the library's \
package when it is loaded, or eval-lisp to inspect its package/exports. A \
remote search is a fallback only when local inspection is unavailable or the \
user explicitly asks for current upstream documentation, releases, or news.

Use tools purposefully and make progress toward a timely answer. Tool work is \
bounded to protect the user from loops and open-ended investigation. If the \
system says the tool budget is exhausted, do not request another tool: give a \
clear final answer from the evidence already obtained, state relevant limits, \
and suggest the most useful next step when needed.

Before writing a new tool or helper function with write-extension or \
eval-lisp, use the lisp-apropos tool to check whether something that \
already does it is already loaded -- this image already has alexandria, \
serapeum, iterate, and trivia loaded, on top of plain Common Lisp and \
cl-agent's own code, so a lot of what you'd otherwise write by hand \
(string splitting/joining, tree flattening, hash-table helpers, that \
kind of thing) likely already exists. Search by a plain substring of \
what you're looking for (e.g. lisp-apropos(\"split\")) -- it's a name \
search across every loaded package, not a type-signature search, so \
try a few different words for the same idea if the first doesn't hit.

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
   (tool-catalog :initarg :tool-catalog :accessor session-tool-catalog
                 :documentation "The full, session-scoped tool inventory. In
:PLAN mode SESSION-TOOLS is a curated working subset of this catalog; direct
mode exposes the full catalog.")
   (orchestration-tool-limit :initarg :orchestration-tool-limit :initform 8
                             :accessor session-orchestration-tool-limit
                             :documentation "Maximum number of tool schemas exposed in
:PLAN mode, including discover-tools. Direct mode does not use this limit.")
   (orchestration-mode :initarg :orchestration-mode :initform :direct
                       :accessor session-orchestration-mode
                       :documentation "How incoming user work is prepared: :DIRECT
submits it normally; :PLAN adds a planning brief; :PLAN-REVIEW also verifies
the proposed final answer with an isolated reviewer.")
   (active-plan :initform nil :accessor session-active-plan)
   (task-record :initform nil :accessor session-task-record
                :documentation "Durable journal entry for the current task.")
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

(defparameter *orchestration-modes* '(:direct :plan :plan-review)
  "Supported first-stage orchestration modes.")

(defun normalize-orchestration-mode (mode)
  "Return MODE as a supported keyword, accepting config keywords and slash
command strings. Unknown or absent values safely select :DIRECT."
  (let ((keyword (cond ((keywordp mode) mode)
                       ((stringp mode) (intern (string-upcase mode) :keyword))
                       (t :direct))))
    (if (member keyword *orchestration-modes*) keyword :direct)))

(defun planning-mode-p (session)
  "True for modes that run the planning and curated-tool stages."
  (member (session-orchestration-mode session) '(:plan :plan-review)))

(defun completion-review-mode-p (session)
  "True only when final answers require phase-three verification."
  (eq (session-orchestration-mode session) :plan-review))

(defun make-session (provider &key frontend system-prompt (tools (list-tools)) max-tool-iterations orchestration-mode orchestration-tool-limit)
  (make-instance 'agent-session
                  :provider provider
                  :frontend (or frontend (make-frontend :cli))
                  :tools tools
                  :tool-catalog tools
                  :orchestration-mode (normalize-orchestration-mode orchestration-mode)
                  :orchestration-tool-limit (if (and (integerp orchestration-tool-limit)
                                                     (<= 1 orchestration-tool-limit))
                                                orchestration-tool-limit
                                                8)
                  :messages (list (list :role "system" :content (or system-prompt *default-system-prompt*)))
                  :max-tool-iterations (or max-tool-iterations 25)))

(defun string-list (value)
  "Keep only string entries from a JSON array-shaped VALUE."
  (and (listp value) (remove-if-not #'stringp value)))

(defun orchestration-tool-catalog (session)
  "Compact planning-time view of SESSION's tools, omitting full schemas."
  (sort (mapcar (lambda (tool) (format nil "~a — ~a" (tool-name tool) (tool-description tool)))
                (session-tool-catalog session))
        #'string<))

(defun find-session-catalog-tool (session name)
  "Find NAME in SESSION's full catalog, not just its currently exposed set."
  (find name (session-tool-catalog session) :key #'tool-name :test #'string=))

(defun session-enable-tools (session names)
  "Add the valid catalog tool NAMES to SESSION's exposed set. Returns the
newly added tools in NAME order, so callers can show an auditable event."
  (let ((newly-enabled nil))
    (dolist (name names)
      (let ((tool (find-session-catalog-tool session name)))
        (when (and tool (not (find (tool-name tool) (session-tools session)
                                  :key #'tool-name :test #'string=)))
          (push tool newly-enabled)
          (setf (session-tools session) (append (session-tools session) (list tool))))))
    (nreverse newly-enabled)))

(defun activate-planned-tools (session brief)
  "Make a plan's validated suggestions operational. DISCOVER-TOOLS is always
available in plan mode so an incomplete plan can recover without restoring a
large tool schema dump. An invalid planner result retains the full catalog."
  (if (getf brief :valid-p)
      (let* ((budget (session-orchestration-tool-limit session))
             (suggested (subseq (getf brief :suggested-tools) 0
                                (min (max 0 (1- budget)) (length (getf brief :suggested-tools)))))
             (names (remove-duplicates (append suggested (list "discover-tools")) :test #'string=))
             (active (remove nil (mapcar (lambda (name) (find-session-catalog-tool session name)) names))))
        (setf (session-tools session) active)
        (ui-system (session-frontend session)
                   (format nil "[tools] Plan mode enabled: ~{~a~^, ~} (budget ~d). Use discover-tools to expand this set."
                           (mapcar #'tool-name active) budget)))
      (progn
        (setf (session-tools session) (copy-list (session-tool-catalog session)))
        (ui-system (session-frontend session)
                   "[tools] Planner output was unusable; keeping the full tool set."))))

(defun parse-planning-brief (response original-text session)
  "Validate planner RESPONSE. Only registered tool names are retained; bad
JSON conservatively falls back to the original request."
  (let* ((decoded (handler-case (and (stringp response) (json-decode response))
                    (error () nil)))
         (rewritten (jget decoded "rewritten_prompt"))
         (known-tools (mapcar #'tool-name (session-tool-catalog session)))
         (suggested (remove-if-not (lambda (name) (member name known-tools :test #'string=))
                                   (string-list (jget decoded "suggested_tools"))))
         (plan (string-list (jget decoded "plan")))
         (verification (string-list (jget decoded "verification"))))
    (list :valid-p (and (hash-table-p decoded) (stringp rewritten)
                        (plusp (length (string-trim " " rewritten))))
          :rewritten-prompt (if (and (stringp rewritten) (plusp (length (string-trim " " rewritten))))
                                rewritten original-text)
          :plan plan :suggested-tools suggested :verification verification)))

(defun format-planning-brief (brief original-text)
  "Render a validated planning BRIEF for the UI and main execution context."
  (with-output-to-string (out)
    (format out "[plan]~%Rewritten task: ~a" (getf brief :rewritten-prompt))
    (when (getf brief :plan) (format out "~%Plan:~%~{  - ~a~%~}" (getf brief :plan)))
    (when (getf brief :suggested-tools)
      (format out "Suggested tools: ~{~a~^, ~}~%" (getf brief :suggested-tools)))
    (when (getf brief :verification)
      (format out "Verification:~%~{  - ~a~%~}" (getf brief :verification)))
    (format out "~%Original request: ~a" original-text)))

(defun plan-user-request (session text)
  "Run phase one's isolated planner and return the execution brief sent to
the main agent. The JSON contract makes intermediate planning inspectable."
  (let* ((catalog (orchestration-tool-catalog session))
         (response (session-complete
                    (format nil "User request:~%~a~%~%Available tools:~%~{~a~%~}" text catalog)
                    :system "You are the planning stage of a coding agent. Reply with JSON only, no Markdown: {\"rewritten_prompt\": string, \"plan\": [string], \"suggested_tools\": [exact tool-name strings], \"verification\": [string]}. Preserve user intent. Suggest only supplied tool names. Do not perform the task, call tools, or claim results."))
         (brief (parse-planning-brief response text session))
         (rendered (format-planning-brief brief text)))
    (ui-system (session-frontend session) rendered)
    (setf (session-active-plan session) brief)
    (activate-planned-tools session brief)
    rendered))

;;; Phase 4: durable task records.  This is intentionally a journal before
;;; introducing workers: every later scheduler/approval mechanism needs these
;;; durable inputs and receipts first.
(defvar *task-record-sequence* 0)

(defun task-record-directory ()
  (merge-pathnames "tasks/" *config-directory*))

(defun persist-task-record (record)
  (ensure-directories-exist (task-record-directory))
  (with-open-file (out (merge-pathnames (format nil "~a.json" (jget record "id"))
                                        (task-record-directory))
                       :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string (json-encode record :pretty t) out))
  record)

(defun start-task-record (session original prepared execution)
  "Start a durable record with plan, state, tool receipts, and approval space."
  (let* ((plan (session-active-plan session))
         (record (jobj "id" (format nil "task-~d-~d" (get-universal-time) (incf *task-record-sequence*))
                       "created_at" (get-universal-time) "status" "executing"
                       "original_request" original "prepared_request" prepared
                       "execution_request" execution
                       "plan" (or (and plan (getf plan :plan)) :empty-array)
                       "verification" (or (and plan (getf plan :verification)) :empty-array)
                       "tool_evidence" :empty-array "pending_approvals" :empty-array)))
    (setf (session-task-record session) record (session-active-plan session) nil)
    (persist-task-record record)))

(defun record-task-tool-evidence (session tool-call result)
  (let ((record (session-task-record session)))
    (when record
      (let ((evidence (jobj "tool" (getf tool-call :name)
                            "arguments" (getf tool-call :arguments)
                            "result" (subseq result 0 (min 12000 (length result))))))
        (setf (gethash "tool_evidence" record)
              (append (let ((old (jget record "tool_evidence"))) (if (listp old) old nil))
                      (list evidence)))
        (persist-task-record record)))))

(defun set-task-record-status (session status &optional detail)
  "Persist the terminal lifecycle STATUS for SESSION's current task.
DETAIL records why a task stopped short of a verified completion."
  (let ((record (session-task-record session)))
    (when record
      (setf (gethash "status" record) status
            (gethash "finished_at" record) (get-universal-time))
      (when detail
        (setf (gethash "status_detail" record) detail))
      (persist-task-record record))))

(defun finish-agent-turn (session message status &optional detail)
  "Record a terminal task state, then return MESSAGE for RUN-AGENT-TURN."
  (set-task-record-status session status detail)
  message)

(defun session-submit-user-text (session text)
  "The one place incoming user input (the initial task, or a line from
SESSION-FRONTEND) turns into a \"user\" role message on SESSION. Threads
TEXT through the :USER-MESSAGE chain hook first (see hooks.lisp) --
a hook registered there sees, and can rewrite or expand, what the
model is about to be asked before its own system prompt or any prior
turn is involved -- then appends the (possibly changed) result.
RUN-REPL calls this instead of appending a message directly; so should
anything else that wants to feed the model a user turn."
  (let* ((ctx (run-hook-chain :user-message (list :text text)))
         (prepared-text (getf ctx :text))
         (execution-text (if (planning-mode-p session)
                             (plan-user-request session prepared-text)
                             prepared-text)))
    (setf (session-messages session)
          (append (session-messages session) (list (list :role "user" :content execution-text))))
    (start-task-record session text prepared-text execution-text)))

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

(defvar *current-session* nil
  "The AGENT-SESSION currently driving a turn -- dynamically bound by
RUN-AGENT-TURN for the duration of that turn, so every hook function
and tool body that runs during it (including a nested SESSION-COMPLETE
call) can reach back to the session it's running inside of, rather
than needing its own separately-configured provider. NIL outside a
running turn.")

(defun session-complete (prompt &key system model)
  "Run PROMPT through *CURRENT-SESSION*'s own provider as one
independent, one-off completion -- SYSTEM (or a plain default) as the
system message, PROMPT as the only user message, no tools -- and
return the reply text (or NIL). Does not touch SESSION-MESSAGES (it's
a side completion, not part of the visible conversation), but does
count toward the session's stats via SESSION-NOTE-REQUEST, since it's
a real request against the same provider and a hidden one would make
/stats lie about how many requests a turn actually made.

This is the primitive for a hook or tool body that wants the model
itself to transform or judge some text, rather than pattern-matching
it by hand -- e.g. an :AFTER-RESPONSE hook that rewrites the
assistant's reply in a different voice, or a :BEFORE-TOOL-CALL hook
that asks the model to judge whether code WRITE-EXTENSION is about to
save has an obvious code smell before deciding whether to veto the
call (see RUN-TOOL-CALL's docstring on vetoing, and
config/example-llm-roundtrip-extension.lisp for both, worked).

Signals a plain error if called with no turn running (*CURRENT-SESSION*
is NIL) -- there is no provider to borrow outside of one."
  (unless *current-session*
    (error "SESSION-COMPLETE needs a running turn (*CURRENT-SESSION* is NIL) -- call it from inside a hook or tool body, not standalone"))
  (let ((provider (if model
                      (provider-for-model (session-provider *current-session*) model)
                      (session-provider *current-session*))))
    (let ((message (chat provider
                        (list (list :role "system" :content (or system "You are a helpful assistant."))
                              (list :role "user" :content prompt))
                        nil)))
      (session-note-request *current-session* message)
      (getf message :content))))

(defun current-turn-review-evidence (session)
  "Render the latest user turn and its tool results for the isolated reviewer."
  (let* ((messages (session-messages session))
         (start (position "user" messages :from-end t :key (lambda (message) (getf message :role))))
         (turn (if start (subseq messages start) nil)))
    (with-output-to-string (out)
      (dolist (message turn)
        (when (member (getf message :role) '("user" "tool") :test #'string=)
          (let ((content (or (getf message :content) "")))
            (format out "~a: ~a~%" (string-upcase (getf message :role))
                    (subseq content 0 (min 12000 (length content))))))))))

(defun parse-completion-review (response)
  "Validate a JSON-only reviewer response; invalid output fails closed."
  (let* ((decoded (handler-case (and (stringp response) (json-decode response))
                    (error () nil)))
         (decision (jget decoded "decision"))
         (reason (jget decoded "reason"))
         (missing (string-list (jget decoded "missing_verification"))))
    (if (and (hash-table-p decoded) (member decision '("accept" "revise" "block") :test #'string=)
             (stringp reason))
        (list :decision (intern (string-upcase decision) :keyword) :reason reason
              :missing-verification missing)
        (list :decision :block
              :reason "The completion reviewer returned unusable output, so completion cannot be verified."
              :missing-verification nil))))

(defun request-completion-review (session assistant-message)
  "Ask an isolated, tool-free reviewer to evaluate the proposed final answer."
  (parse-completion-review
   (session-complete
    (format nil "Task evidence from this turn:~%~a~%~%Proposed final answer:~%~a"
            (current-turn-review-evidence session) (or (getf assistant-message :content) ""))
    :system "You are a completion verifier for a coding agent. Judge the proposed final answer against the user request, plan, verification criteria, and tool evidence. Do not trust unsupported claims. Reply with JSON only: {\"decision\": \"accept\"|\"revise\"|\"block\", \"reason\": string, \"missing_verification\": [string]}. Accept only when evidence supports completion. Revise means one concrete follow-up can establish it. Block means the task cannot currently be verified. You have no tools and must not perform work.")))

(defun format-completion-review (review)
  "Human-visible audit record for a completion review result."
  (format nil "[review] ~a: ~a~@[~%Missing verification: ~{~a~^; ~}~]"
          (string-upcase (string (getf review :decision))) (getf review :reason)
          (getf review :missing-verification)))

(defun parse-tool-budget-review (response)
  "Validate the isolated tool-budget review. Invalid output conservatively
declines an extension so a malformed reviewer cannot create open-ended work."
  (let* ((decoded (handler-case (and (stringp response) (json-decode response))
                    (error () nil)))
         (decision (jget decoded "decision"))
         (reason (jget decoded "reason"))
         (extra-rounds (jget decoded "extra_rounds")))
    (if (and (hash-table-p decoded)
             (member decision '("extend" "finish") :test #'string=)
             (stringp reason)
             (or (string= decision "finish")
                 (and (integerp extra-rounds) (<= 1 extra-rounds 3))))
        (list :decision (intern (string-upcase decision) :keyword)
              :reason reason
              :extra-rounds (if (string= decision "extend") extra-rounds 0))
        (list :decision :finish
              :reason "The tool-budget reviewer returned unusable output; preserving a timely response."
              :extra-rounds 0))))

(defun request-tool-budget-review (session iteration limit)
  "Ask a tool-free reviewer whether a small, one-time extension benefits the user."
  (parse-tool-budget-review
   (session-complete
    (format nil "The agent reached its tool-round limit (~d) at round ~d.~%~%Task evidence so far:~%~a"
            limit iteration (current-turn-review-evidence session))
    :system "You are a conservative tool-budget reviewer for an agent. Protect the user's time and attention: approve a small extension only when evidence shows concrete progress and a clear, near-term path to materially improve the answer. Do not approve exploratory, repetitive, or speculative work, and do not ask the user a question. If additional work is unlikely to finish promptly, require a timely final answer that states what is known and what remains. Reply with JSON only: {\"decision\": \"extend\"|\"finish\", \"reason\": string, \"extra_rounds\": integer}. For extend, extra_rounds must be 1, 2, or 3; it is a one-time bounded extension. For finish, use 0.")))

(defun tool-budget-skipped-results (tool-calls reason)
  "Produce protocol-valid synthetic tool results when the budget declines work.
Every assistant tool call must receive a tool result before the next request."
  (mapcar (lambda (tool-call)
            (list :role "tool" :tool-call-id (getf tool-call :id)
                  :content (format nil "Tool call was not run because the tool budget was exhausted: ~a" reason)))
          tool-calls))

(defun tool-call-json-error (tool-call)
  "Return a model-readable validation error for TOOL-CALL, or NIL.

Providers preserve malformed argument JSON as :ARGUMENTS-ERROR rather than
silently replacing it with {}, and this second check validates the decoded
object against the exact schema sent to the model."
  (or (getf tool-call :arguments-error)
      (unless (json-object-p (getf tool-call :arguments))
        "expected a JSON object")
      (let ((tool (find-tool (getf tool-call :name))))
        (and tool
             (json-schema-validation-error (getf tool-call :arguments)
                                           (tool-parameters tool))))))

(defun invalid-tool-call-result (tool-call problem)
  "Feedback returned to the model when it emits invalid tool-call JSON."
  (format nil "Tool call was not run because its JSON arguments are invalid: ~a. ~
               Call ~a again with a JSON object that matches the advertised schema."
          problem (getf tool-call :name)))

(defparameter *shell-command-inspection-enabled* t
  "When true, inspect model-proposed shell commands before execution.

The inspector is deliberately about relevance, scope, and evidence quality,
not user authorization.  A rejected command is returned to the model as tool
feedback so it can choose a narrower or more direct next step.")

(defparameter *whole-host-search-programs*
  '("find" "locate" "fd" "fdfind" "rg" "grep" "ag" "ack")
  "Programs whose use can turn a path argument into a broad discovery scan.

This is deliberately a property of shell command shape, not a list of
libraries, files, or user requests.  The model inspector evaluates every
other question of relevance; this preflight reserves an unscoped whole-host
scan as categorically disproportionate for an agent's exploratory step.")

(defun shell-command-tokens (command)
  "Split enough shell punctuation to inspect the shape of a proposed command.

This is not a shell parser: it recognizes ordinary agent-generated commands
and deliberately fails closed only for an unmistakable whole-host traversal."
  (remove-if (lambda (token) (zerop (length token)))
             (uiop:split-string command :separator '(#\Space #\Tab #\Newline #\; #\| #\&))))

(defun whole-host-shell-search-reason (command)
  "Return a reason when COMMAND asks a discovery tool to traverse the host root.

Searching from the filesystem root has an unbounded scope and is not an
appropriate fallback for locating a dependency or answering a normal task.
The caller reports this as tool feedback rather than asking the user."
  (let ((tokens (and (stringp command) (shell-command-tokens command))))
    (when (and tokens
               (some (lambda (program) (member program *whole-host-search-programs*
                                               :test #'string=))
                     tokens)
               (member "/" tokens :test #'string=))
      "The command would perform an unscoped search of the entire host filesystem. Use a known project, package-manager, or runtime-specific location instead.")))

(defun parse-shell-command-inspection (response)
  "Validate the JSON-only result from the isolated shell command inspector."
  (let* ((decoded (handler-case (and (stringp response) (json-decode response))
                    (error () nil)))
         (decision (jget decoded "decision"))
         (reason (jget decoded "reason"))
         (alternative (jget decoded "alternative")))
    (if (and (hash-table-p decoded)
             (member decision '("allow" "reject") :test #'string=)
             (stringp reason)
             (or (null alternative) (stringp alternative)))
        (list :decision (intern (string-upcase decision) :keyword)
              :reason reason :alternative alternative)
        ;; The inspector is a safety boundary: malformed output must not
        ;; silently permit a command whose relevance was never assessed.
        (list :decision :reject
              :reason "The shell-command inspector returned unusable output."
              :alternative "Choose a bounded command with a specific target."))))

(defun inspect-shell-command (session command)
  "Ask a tool-free reviewer whether COMMAND is a justified shell action.

SESSION supplies the actual task and evidence, preventing the reviewer from
judging a command in isolation.  It never asks the user for permission."
  (let ((whole-host-reason (whole-host-shell-search-reason command)))
    (if whole-host-reason
        ;; A model cannot override this: whole-host discovery has no bounded
        ;; evidence target, regardless of how confidently it proposes it.
        (list :decision :reject :reason whole-host-reason
              :alternative "Inspect the package manager, language runtime, or another known location.")
        (parse-shell-command-inspection
         (let ((*current-session* session))
           (session-complete
            (format nil "Current task and evidence:~%~a~%~%Proposed shell command:~%~a"
                    (current-turn-review-evidence session) command)
            :system "You are a conservative shell-command inspector for a coding agent. Reject by default unless the command has a concrete, bounded target and a direct evidence need that follows from the task. Allow only if you can state both (1) the exact evidence it will obtain and (2) why the command's scope is the smallest reasonable one. Reject commands that gather information more broadly than the task/evidence justifies, have an unbounded or poorly targeted search space, duplicate available direct evidence, or are unlikely to answer the question. This is not a permission check: do not ask the user anything and do not consider authorization. Reply JSON only: {\"decision\": \"allow\"|\"reject\", \"reason\": string, \"alternative\": string|null}."))))))

(defun rejected-shell-command-result (inspection)
  "Feedback returned to the model when command inspection rejects a shell call."
  (format nil "Shell command was not run: ~a~@[ Safer next step: ~a~]"
          (getf inspection :reason) (getf inspection :alternative)))

(defun run-tool-call (session tool-call)
  "Run one normalized tool-call plist (:id :name :arguments), wrapped
in the :before-tool-call / :after-tool-call chain hooks and
SESSION-FRONTEND's UI-TOOL-STARTED/UI-TOOL-FINISHED, and return the
normalized \"tool\" role message to append to the conversation.

A :before-tool-call hook function that signals an error vetoes the
call: the tool itself never runs (so e.g. write-extension never writes
its file), :after-tool-call never fires either (nothing actually ran
for it to react to), and the condition's REPORT text becomes the
\"tool\" message's content instead -- the model sees why its call was
refused and can adjust, the same as any other tool error (see
CALL-TOOL), rather than the error propagating out of the turn
entirely."
  (let* ((frontend (session-frontend session))
         (validation-error (tool-call-json-error tool-call))
         (shell-inspection
           (when (and (not validation-error)
                      *shell-command-inspection-enabled*
                      (string= (getf tool-call :name) "shell")
                      *current-session*)
             (inspect-shell-command session (jget (getf tool-call :arguments) "command"))))
         (inspection-error (and shell-inspection
                                (eq (getf shell-inspection :decision) :reject)
                                (rejected-shell-command-result shell-inspection)))
         (requested (list :tool-name (getf tool-call :name) :arguments (getf tool-call :arguments))))
    (multiple-value-bind (ctx veto)
        (if (or validation-error inspection-error)
            (values requested nil)
            (handler-case (values (run-hook-chain :before-tool-call requested) nil)
              (error (c) (values requested c))))
      (ui-tool-started frontend (getf ctx :tool-name) (getf ctx :arguments))
      (when inspection-error
        (ui-system frontend (format nil "[shell inspector] ~a" (getf shell-inspection :reason))))
      (let* ((result (cond (validation-error (invalid-tool-call-result tool-call validation-error))
                           (inspection-error inspection-error)
                           (veto (format nil "Tool call vetoed by a :before-tool-call hook: ~a" veto))
                           (t (call-tool (getf ctx :tool-name) (getf ctx :arguments)))))
             (after (if (or validation-error inspection-error veto)
                        (list* :result result ctx)
                        (run-hook-chain :after-tool-call
                                        (list :tool-name (getf ctx :tool-name)
                                              :arguments (getf ctx :arguments)
                                              :result result)))))
      (ui-tool-finished frontend (getf ctx :tool-name) (getf ctx :arguments) (getf after :result))
      (record-task-tool-evidence session tool-call (getf after :result))
      (incf (getf (session-raw-stats session) :tool-calls))
      (ui-stats-updated frontend (session-stats-snapshot session))
      (list :role "tool" :tool-call-id (getf tool-call :id) :content (getf after :result))))))

(defun run-agent-turn (session)
  "Drive SESSION forward: send the current message history to the
provider via CHAT-STREAM (providers/provider.lisp), relaying each
incremental chunk to SESSION-FRONTEND's UI-ASSISTANT-DELTA as it
arrives (while one UI-THINKING-STARTED/STOPPED interval brackets the
entire agent turn, including tool work and follow-up requests) and the complete
text to UI-ASSISTANT-TEXT once the response is done, run any requested
tool calls and feed their results back, and repeat until the model
replies with no tool calls (an ordinary turn) or SESSION-MAX-TOOL-
ITERATIONS is hit (a safety valve against an infinite tool-call loop --
the loop is broken with a synthetic system note appended to the
history, not an error, so the conversation can continue normally
afterward). Updates SESSION's running stats (SESSION-STATS-SNAPSHOT)
and fires UI-STATS-UPDATED after every request and tool call. Binds
*CURRENT-SESSION* for the duration, so a hook or tool body running
during this turn can call SESSION-COMPLETE."
  (let ((frontend (session-frontend session))
        (*current-session* session)
        ;; One automatic revision is enough to make review feedback actionable
        ;; without trapping a task whose least-bad solution retains a smell.
        (lisp-review-retries 0)
        (review-tool-used-p nil)
        (completion-review-retries 0)
        (tool-iteration-limit (session-max-tool-iterations session))
        (tool-budget-extension-used-p nil)
        (tool-budget-finalization-p nil))
    ;; A tool-using turn can make several model requests.  Keep one stable
    ;; activity indicator across the whole turn rather than flashing it off
    ;; after each response and back on for the follow-up request.
    (ui-thinking-started frontend)
    (unwind-protect
         (loop for iteration from 1
          do (let* ((ctx (run-hook-chain :before-request
                                          (list :messages (session-messages session)
                                                ;; A denied budget becomes a no-tool final-answer pass.
                                                :tools (unless tool-budget-finalization-p
                                                         (session-tools session)))))
                    (assistant-message
                      (handler-case
                          (chat-stream (session-provider session) (getf ctx :messages) (getf ctx :tools)
                                       (lambda (chunk) (ui-assistant-delta frontend chunk)))
                        (provider-error (c)
                          (run-hook :on-error c)
                          (ui-error frontend c)
                          (return-from run-agent-turn
                            (finish-agent-turn session nil "blocked" (princ-to-string c)))))))
               (setf assistant-message (run-hook-chain :after-response assistant-message))
               ;; Normalize harmless formatting noise before it is visible or
               ;; reaches the strict Lisp reviewer, avoiding spurious warnings.
               (when (stringp (getf assistant-message :content))
                 (setf (getf assistant-message :content)
                       (normalize-assistant-common-lisp (getf assistant-message :content))))
               (setf (session-messages session) (append (session-messages session) (list assistant-message)))
               (session-note-request session assistant-message)
               (let* ((reviews (review-assistant-common-lisp (getf assistant-message :content)))
                      (request-revision-p
                        (and reviews
                             (not review-tool-used-p)
                             (zerop lisp-review-retries)
                             (some #'lisp-review-needs-revision-p reviews))))
                 (if request-revision-p
                     (progn
                       (incf lisp-review-retries)
                       (setf (session-messages session)
                             (append (session-messages session)
                                     (list (list :role "system"
                                                 :content (format-assistant-lisp-reviews reviews)))))
                       (ui-system frontend "[cl-agent] generated Lisp had review findings; requesting one revision.")
                       (ui-stats-updated frontend (session-stats-snapshot session)))
                     (let ((tool-calls (getf assistant-message :tool-calls)))
                       ;; A plan-review final stays hidden until the reviewer
                       ;; accepts it; tool-bearing replies retain normal live UI.
                       (when (and tool-calls (not (ui-show-tool-call-assistant-text-p frontend)))
                         (ui-discard-assistant-pending frontend))
                       (unless (or (and (null tool-calls) (completion-review-mode-p session))
                                   (and tool-calls (not (ui-show-tool-call-assistant-text-p frontend))))
                         (when (getf assistant-message :content)
                           (ui-assistant-text frontend (getf assistant-message :content)))
                         (ui-stats-updated frontend (session-stats-snapshot session)))
                       (cond
                         ((null tool-calls)
                          (if (not (completion-review-mode-p session))
                              (return-from run-agent-turn
                                (finish-agent-turn session assistant-message "completed"))
                              (let ((review (request-completion-review session assistant-message)))
                                (ui-system frontend (format-completion-review review))
                                (ui-stats-updated frontend (session-stats-snapshot session))
                                (case (getf review :decision)
                                  (:accept
                                   (when (getf assistant-message :content)
                                     (ui-assistant-text frontend (getf assistant-message :content)))
                                   (return-from run-agent-turn
                                     (finish-agent-turn session assistant-message "completed")))
                                  (:revise
                                   (if (zerop completion-review-retries)
                                       (progn
                                         (incf completion-review-retries)
                                         (setf (session-messages session)
                                               (append (session-messages session)
                                                       (list (list :role "system"
                                                                   :content (format nil "Completion review requires one revision: ~a~@[ Missing verification: ~{~a~^; ~}.~] Do the required verification, then provide a corrected final answer."
                                                                                    (getf review :reason)
                                                                                    (getf review :missing-verification)))))))
                                       (progn
                                         (ui-system frontend "[review] Revision budget exhausted; completion remains unverified.")
                                         (return-from run-agent-turn
                                           (finish-agent-turn session assistant-message "blocked"
                                                              "Completion review revision budget exhausted.")))))
                                  (:block
                                   (setf (session-messages session)
                                         (append (session-messages session)
                                                 (list (list :role "system"
                                                             :content (format nil "Completion blocked by independent review: ~a"
                                                                              (getf review :reason))))))
                                   (return-from run-agent-turn
                                     (finish-agent-turn session assistant-message "blocked"
                                                        (getf review :reason))))))))
                         ((>= iteration tool-iteration-limit)
                          (let ((review (if tool-budget-extension-used-p
                                            (list :decision :finish :extra-rounds 0
                                                  :reason "The one-time tool-budget extension has already been used.")
                                            (request-tool-budget-review session iteration tool-iteration-limit))))
                            (if (eq (getf review :decision) :extend)
                                (progn
                                  (setf tool-budget-extension-used-p t)
                                  ;; Include this proposed round, plus the bounded
                                  ;; number of follow-up rounds the reviewer approved.
                                  (incf tool-iteration-limit (1+ (getf review :extra-rounds)))
                                  (ui-system frontend
                                             (format nil "[tool budget] Extended through round ~d: ~a"
                                                     tool-iteration-limit (getf review :reason)))
                                  (dolist (tc tool-calls)
                                    (when (string= (getf tc :name) "review-lisp")
                                      (setf review-tool-used-p t))
                                    (setf (session-messages session)
                                          (append (session-messages session)
                                                  (list (run-tool-call session tc))))))
                                (progn
                                  ;; Do not leave unanswered tool calls in provider history:
                                  ;; OpenAI-compatible APIs require a result for each one.
                                  (setf (session-messages session)
                                        (append (session-messages session)
                                                (tool-budget-skipped-results tool-calls (getf review :reason))
                                                (list (list :role "system"
                                                            :content (format nil "Tool budget exhausted. Do not call tools. Provide the user a timely final answer using the evidence already collected; be candid about limits and suggest a useful next step if needed. Reviewer rationale: ~a"
                                                                             (getf review :reason))))))
                                  (setf tool-budget-finalization-p t)
                                  (ui-system frontend
                                             (format nil "[tool budget] Continuing without tools for a final answer: ~a"
                                                     (getf review :reason)))))))
                         (t
                          (dolist (tc tool-calls)
                            (when (string= (getf tc :name) "review-lisp")
                              (setf review-tool-used-p t))
                            (setf (session-messages session)
                                  (append (session-messages session)
                                          (list (run-tool-call session tc))))))))))))
      (ui-thinking-stopped frontend))))

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
  (setf (session-tool-catalog session) (list-tools))
  (if (eq (session-orchestration-mode session) :direct)
      (setf (session-tools session) (copy-list (session-tool-catalog session)))
      (session-enable-tools session (mapcar #'tool-name (session-tools session))))
  t)

(define-slash-command provider (session arg)
  (declare (ignore arg))
  (ui-system (session-frontend session)
             (format nil "~a, model ~a" (provider-display-name (session-provider session))
                     (provider-model (session-provider session))))
  t)

(define-slash-command model (session arg)
  "Usage: /model to list live provider model IDs, or /model MODEL (or its
number in that list) to select it for subsequent requests in this session.
The choice is intentionally session-local; config and other sessions are not
rewritten behind the user's back."
  (let ((frontend (session-frontend session)))
    (handler-case
        (let ((models (provider-list-models (session-provider session)))
              (choice (string-trim " " arg)))
          (cond
            ((null models)
             (ui-system frontend "This provider does not expose any models through /models."))
            ((zerop (length choice))
             (ui-system frontend
                        (format nil "Available models:~%~{~a~^~%~}"
                                (loop for model in models for index from 1
                                      collect (format nil "~d) ~a" index model)))))
            (t
             (let ((selected (or (ignore-errors
                                   (let ((index (parse-integer choice :junk-allowed nil)))
                                     (and (<= 1 index (length models)) (nth (1- index) models))))
                                 (and (member choice models :test #'string=) choice))))
               (if selected
                   (progn
                     (setf (provider-model (session-provider session)) selected)
                     (ui-system frontend (format nil "Model switched to ~a." selected))
                     (ui-stats-updated frontend (session-stats-snapshot session)))
                   (ui-system frontend
                              (format nil "Unknown model ~s. Run /model to list valid models." choice)))))))
      (provider-error (c)
        (ui-error frontend c))))
  t)

(define-slash-command mode (session arg)
  "Usage: /mode to show the pipeline mode, or /mode direct|plan|plan-review.
Plan mode makes a visible planning request; plan-review also verifies finals."
  (let* ((frontend (session-frontend session)) (choice (string-trim " " arg)))
    (if (zerop (length choice))
        (ui-system frontend (format nil "Orchestration mode: ~a. Available: ~{~(~a~)~^, ~}."
                                   (session-orchestration-mode session) *orchestration-modes*))
        (let ((requested (intern (string-upcase choice) :keyword)))
          (if (member requested *orchestration-modes*)
              (progn (setf (session-orchestration-mode session) requested)
                     (when (eq requested :direct)
                       (setf (session-tools session) (copy-list (session-tool-catalog session))))
                     (ui-system frontend (format nil "Orchestration mode switched to ~a." requested)))
              (ui-system frontend (format nil "Unknown mode ~s. Available: ~{~(~a~)~^, ~}."
                                          choice *orchestration-modes*))))))
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
/command specially, otherwise submit it as a user message (via SESSION-
SUBMIT-USER-TEXT -- see its docstring on the :USER-MESSAGE hook) and
run a turn. Fires :ON-STARTUP before the first prompt and :ON-SHUTDOWN
on the way out (including via end-of-input / an interrupt reaching
here as a condition), and brackets the whole session in SESSION-
FRONTEND's UI-START/UI-STOP. Binds *CURRENT-SESSION* for the whole
session lifetime, not just a single turn, so a :USER-MESSAGE hook
(which runs before RUN-AGENT-TURN's own narrower binding takes effect)
can still call SESSION-COMPLETE."
  (let ((frontend (session-frontend session))
        (*current-session* session))
    (ui-start frontend)
    (unwind-protect
         (progn
           (run-hook :on-startup)
           (unwind-protect
                (progn
                  (when (and initial-task (plusp (length initial-task)))
                    (session-submit-user-text session initial-task)
                    (run-agent-turn session))
                  (loop
                    (let ((line (ui-prompt-input frontend)))
                      (unless line (return))
                      (when (plusp (length (string-trim " " line)))
                        (let ((result (dispatch-slash-command session line)))
                          (cond
                            ((eq result :not-a-command)
                             (session-submit-user-text session line)
                             (run-agent-turn session))
                            ((null result) (return))))))))
             (run-hook :on-shutdown)))
      (ui-stop frontend)))
  (values))
