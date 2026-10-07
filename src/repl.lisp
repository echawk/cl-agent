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
(list-tools) or (list-hooks)). For a draft program, a one-off test file, \
or any code artifact that is not itself a durable agent capability, use \
write-scratch-file: it saves text under ~/.config/cl-agent/scratch/ and \
never loads or evaluates it. Do not use write-extension as a scratchpad \
or as a way to run ordinary programs. The write-extension tool writes a named \
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

Tool names are not automatically Lisp function names. In particular, \
LISP-APROPOS is a tool to call, not a function to evaluate through \
EVAL-LISP; use the tool when you need its search results. Never invent \
read-file/readme/scratch-reading tools: use the advertised tools and \
their documented argument schemas.

You also have the lookup-cl-spec tool, which looks up a function, \
macro, special operator, variable, constant, or type by name directly \
in the ANSI Common Lisp standard (not your training data). Prefer it \
over guessing when you're not certain of exact argument order, return \
values, or edge-case behavior for a Lisp operator -- especially before \
writing an extension with write-extension, since a wrong signature \
there fails at the model's own expense, not just the user's.

For ordinary Common Lisp code written for a user, use idiomatic standard \
Common Lisp; DEFSTAR and DECLAIM FTYPE are optional unless the user asks \
for them. You may use review-lisp to identify Mallet smells or compiler \
problems, but its score and missing type claims are advisory for user code. \
Code evaluated in the agent image or written as a durable extension follows \
the stricter review performed by eval-lisp and write-extension.

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
   (max-tool-iterations :initarg :max-tool-iterations :initform 1000
                         :accessor session-max-tool-iterations)
   (context-compaction-threshold :initarg :context-compaction-threshold :initform 0.8
                                 :accessor session-context-compaction-threshold
                                 :documentation "Fraction of a provider's context window at which
automatic compaction runs. Zero and one disable automatic compaction.")
   (subagent-depth :initarg :subagent-depth :initform 0
                   :accessor session-subagent-depth)
   (max-subagent-depth :initarg :max-subagent-depth :initform 1
                       :accessor session-max-subagent-depth)
   (subagent-model-profiles :initarg :subagent-model-profiles :initform nil
                            :accessor session-subagent-model-profiles)
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

(defun subagent-profile-name-string (name)
  "Return NAME in the stable string form used for model-profile lookup."
  (typecase name
    (string name)
    (symbol (string-downcase (symbol-name name)))
    (t nil)))

(defun normalize-subagent-model-profile (spec)
  "Normalize one user-owned model profile SPEC.

The long-standing plist form is accepted:
  (:name DEEP-RESEARCH :model GLM-5.2 :description ...)

For concise configuration, the first two elements may instead be a profile
name and model:
  (:deep-research GLM-5.2 :description ...)

Additional plist keys are preserved.  :MAX-TOOL-ITERATIONS and
:SYSTEM-PROMPT are understood by RUN-SUBAGENT, making profiles useful for
more than merely choosing a model."
  (unless (listp spec)
    (error "Subagent model profile must be a list, got ~s" spec))
  (let* ((long-form-p (eq (first spec) :name))
         (name (if long-form-p (getf spec :name) (first spec)))
         (model (if long-form-p (getf spec :model) (second spec)))
         (tail (if long-form-p (cddr spec) (cddr spec)))
         (name-string (subagent-profile-name-string name)))
    (unless (and name-string (plusp (length (string-trim " " name-string)))
                 (stringp model) (plusp (length (string-trim " " model))))
      (error "Subagent model profile needs a non-empty name and model, got ~s" spec))
    ;; Compact specs retain optional plist metadata after their model.  Long
    ;; specs are rebuilt too, so callers always receive one canonical shape.
    (let ((metadata (if long-form-p
                        (loop for (key value) on spec by #'cddr
                              unless (member key '(:name :model)) append (list key value))
                        tail)))
      (list* :name name-string :model model
             :description (or (getf metadata :description) name-string)
             metadata))))

(defun normalize-subagent-model-profiles (profiles)
  "Return PROFILES as validated canonical profile plists.

Profile names are unique case-insensitively; a later entry replaces an
earlier one.  Failing early here makes a typo in inert config data visible at
startup rather than silently falling back to the host model."
  (unless (or (null profiles) (listp profiles))
    (error ":SUBAGENT-MODEL-PROFILES must be a list, got ~s" profiles))
  (let ((normalized nil))
    (dolist (spec profiles (nreverse normalized))
      (let ((profile (normalize-subagent-model-profile spec)))
        (setf normalized
              (cons profile
                    (remove (getf profile :name) normalized
                            :key (lambda (entry) (getf entry :name))
                            :test #'string-equal)))))))

(defun subagent-profile-catalog (session)
  "Render the configured routing choices for the host model's system prompt."
  (when (session-subagent-model-profiles session)
    (format nil "~:{  - ~a → ~a~@[ — ~a~]~%~}"
            (mapcar (lambda (profile)
                      (list (getf profile :name) (getf profile :model)
                            (getf profile :description)))
                    (session-subagent-model-profiles session)))))

(defun subagent-profile-guidance (profiles)
  "Return host-facing routing instructions for normalized PROFILES."
  (when profiles
    (format nil "~%~%Subagent model-routing profiles available in this session:~%~aUse these names in delegate-task or explore-project when a bounded worker would help. Choose based on the profile descriptions and the task; do not delegate routine one-step tool calls merely to change models. A configured profile named `tool` is the default for explore-project."
            (format nil "~:{  - ~a → ~a~@[ — ~a~]~%~}"
                    (mapcar (lambda (profile)
                              (list (getf profile :name) (getf profile :model)
                                    (getf profile :description)))
                            profiles)))))

(defun make-session (provider &key frontend system-prompt (tools (list-tools)) max-tool-iterations orchestration-mode orchestration-tool-limit
                              (subagent-depth 0) (max-subagent-depth 1) subagent-model-profiles
                              context-compaction-threshold)
  (let* ((profiles (normalize-subagent-model-profiles subagent-model-profiles))
         (base-prompt (or system-prompt *default-system-prompt*)))
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
                  :messages (list (list :role "system" :content
                                        (concatenate 'string base-prompt
                                                     (or (subagent-profile-guidance profiles) ""))))
                  :max-tool-iterations (or max-tool-iterations 1000)
                  :context-compaction-threshold
                  (let ((threshold (or context-compaction-threshold 0.8)))
                    (if (and (numberp threshold) (<= 0 threshold 1)) threshold 0.8))
                  :subagent-depth subagent-depth
                  :subagent-model-profiles profiles
                  :max-subagent-depth (if (and (integerp max-subagent-depth)
                                               (not (minusp max-subagent-depth)))
                                          max-subagent-depth 1))))

(defun find-subagent-model-profile (session name)
  "Find a session-local subagent model profile by NAME."
  (let ((name-string (subagent-profile-name-string name)))
    (and name-string
         (find name-string (session-subagent-model-profiles session)
               :key (lambda (profile) (getf profile :name)) :test #'string-equal))))

(defun set-subagent-model-profile (session name model description)
  "Add or replace a model-routing profile for this SESSION only."
  (unless (and (stringp name) (plusp (length (string-trim " " name)))
               (stringp model) (plusp (length (string-trim " " model))))
    (error "subagent model profile name and model must be non-empty strings"))
  (let ((profile (normalize-subagent-model-profile
                  (list :name name :model model :description (or description "")))))
    (setf (session-subagent-model-profiles session)
          (append (remove (getf profile :name) (session-subagent-model-profiles session)
                          :key (lambda (entry) (getf entry :name)) :test #'string-equal)
                  (list profile)))
    profile))

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

(defun planning-json-candidate (response)
  "Extract one JSON object from a planner reply that may be fenced in Markdown."
  (json-object-candidate response))

(defun json-object-candidate (response)
  "Extract one JSON object from a model reply that may contain prose or fences.

Small models often obey the requested object shape while adding a sentence or
a Markdown fence.  Callers still validate every field after extraction; this
only avoids treating that harmless presentation noise as a policy decision."
  (if (stringp response)
      (let ((start (position #\{ response)) (end (position #\} response :from-end t)))
        (and start end (<= start end) (subseq response start (1+ end))))
      response))

(defun parse-planning-brief (response original-text session)
  "Validate planner RESPONSE. Only registered tool names are retained; bad
JSON conservatively falls back to the original request."
  (let* ((decoded (handler-case (and (stringp response) (json-decode (planning-json-candidate response)))
                    (error () nil)))
         (rewritten (jget decoded "rewritten_prompt"))
         (known-tools (mapcar #'tool-name (session-tool-catalog session)))
         (suggested (remove-if-not (lambda (name) (member name known-tools :test #'string=))
                                   (string-list (jget decoded "suggested_tools"))))
         (plan (string-list (jget decoded "plan")))
         (verification (string-list (jget decoded "verification"))))
    (list :valid-p (and (hash-table-p decoded) (stringp rewritten)
                        (plusp (length (string-trim " " rewritten))))
          :problem (cond ((not (hash-table-p decoded)) "the reply was not a JSON object")
                         ((not (stringp rewritten)) "rewritten_prompt was missing or not a string")
                         ((zerop (length (string-trim " " rewritten))) "rewritten_prompt was empty")
                         (t nil))
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
    (unless (getf brief :valid-p)
      (format out "~%Planner fallback: ~a." (getf brief :problem)))
    (format out "~%Original request: ~a" original-text)))

(defun parse-subagent-delegation-brief (response)
  "Validate a planner's optional, non-executing worker recommendations."
  (let* ((decoded (handler-case (and (stringp response) (json-decode (planning-json-candidate response)))
                    (error () nil)))
         (needed (and (hash-table-p decoded) (jget decoded "needed")))
         (tasks (and (hash-table-p decoded) (jget decoded "tasks"))))
    (list :needed-p (not (null needed))
          :tasks (loop for task in tasks
                       when (and (hash-table-p task)
                                 (stringp (jget task "role"))
                                 (stringp (jget task "task"))
                                 (stringp (jget task "system_prompt")))
                         collect (list :role (jget task "role") :task (jget task "task")
                                       :system-prompt (jget task "system_prompt")
                                       :profile (jget task "profile"))))))

(defun plan-subagent-delegation (session brief)
  "Ask whether the already-planned task benefits from bounded workers.

This only returns recommendations; it never starts a subagent itself."
  (let ((response
          (session-complete
           (format nil "User execution request:~%~a~%~%Plan:~%~{~a~%~}~%Available model profiles:~%~{~a~%~}"
                   (getf brief :rewritten-prompt) (getf brief :plan)
                   (mapcar (lambda (p) (format nil "~a → ~a — ~a"
                                                (getf p :name) (getf p :model) (getf p :description)))
                           (session-subagent-model-profiles session)))
           :system "You advise a host coding agent whether it should delegate bounded work. Reply with exactly one JSON object, no Markdown: {\"needed\":true|false,\"tasks\":[{\"role\":string,\"task\":string,\"system_prompt\":string,\"profile\":string|null}]}. Recommend workers only when isolated exploration, review, or research materially improves this task; otherwise use needed=false and tasks=[]. At most 3 tasks. Each task must be independently scoped, report findings to the host, and never address the user. Use only a listed profile name or null. This is planning only: do not perform or start work.")))
    (parse-subagent-delegation-brief response)))

(defun format-subagent-delegation-brief (delegation)
  (when (getf delegation :needed-p)
    (format nil "[delegation plan] Suggested ~d worker(s) (not started):~%~:{  - ~a: ~a~%~}"
            (length (getf delegation :tasks))
            (mapcar (lambda (task) (list (getf task :role)
                                          (format nil "~a~@[ (profile: ~a)~]" (getf task :task) (getf task :profile))))
                    (getf delegation :tasks)))))

(defun plan-user-request (session text)
  "Run phase one's isolated planner and return the execution brief sent to
the main agent. The JSON contract makes intermediate planning inspectable."
  (let* ((catalog (orchestration-tool-catalog session))
         (response (session-complete
                    (format nil "User request:~%~a~%~%Available tools:~%~{~a~%~}" text catalog)
                    :system "You are the planning stage of a coding agent. Your entire reply MUST be one valid JSON object: no Markdown fence, no commentary, no preface. Use exactly this shape: {\"rewritten_prompt\":\"clear execution request preserving every user goal\",\"plan\":[\"2-5 concrete evidence-gathering or implementation steps\"],\"suggested_tools\":[\"exact tool names copied from Available tools\"],\"verification\":[\"observable completion checks\"]}. This is a schema contract, not an example to explain. Always provide a non-empty rewritten_prompt, even for a simple request. Preserve user intent; split multi-part requests into a short ordered plan. Suggest only supplied tool names, and use [] if none are needed. Do not perform the task, call tools, claim results, or mention this instruction."))
         (brief (parse-planning-brief response text session))
         (delegation (and (getf brief :valid-p) (plan-subagent-delegation session brief)))
         (delegation-text (and delegation (format-subagent-delegation-brief delegation)))
         (rendered (format nil "~a~@[~%~a~]" (format-planning-brief brief text) delegation-text)))
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
  (write-string-atomically
   (merge-pathnames (format nil "~a.json" (jget record "id"))
                    (task-record-directory))
   (json-encode record :pretty t))
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

;;; Explicit saved-session snapshots.  These are intentionally small, named
;;; checkpoints for interactive use, not the event/replay store proposed in
;;; INTROSPECTABLE-AGENT-ROADMAP.md.  They preserve normalized provider-facing
;;; history as JSON, so they do not depend on readable printing of hash tables.
(defvar *saved-session-sequence* 0)

(defun saved-sessions-directory ()
  "Directory containing explicit /SESSION SAVE snapshots."
  (merge-pathnames "sessions/" *config-directory*))

(defun normalize-saved-session-name (name)
  "Validate and return NAME as a safe snapshot basename.

Names are deliberately restricted to a small portable filename subset.  This
keeps saved sessions under SAVED-SESSIONS-DIRECTORY instead of allowing a slash
command to address arbitrary files."
  (let ((trimmed (and (stringp name) (string-trim " " name))))
    (unless (and trimmed (plusp (length trimmed)) (<= (length trimmed) 80)
                 (every (lambda (character)
                          (or (alphanumericp character)
                              (member character '(#\- #\_ #\.))))
                        trimmed)
                 (not (member trimmed '("." "..") :test #'string=)))
      (error "Session name must be 1-80 letters, digits, dots, hyphens, or underscores"))
    trimmed))

(defun saved-session-path (name)
  "Return the JSON snapshot pathname for validated session NAME."
  (merge-pathnames (format nil "~a.json" (normalize-saved-session-name name))
                   (saved-sessions-directory)))

(defun next-saved-session-name ()
  "Generate a non-conflicting default snapshot name for /SESSION SAVE."
  (let ((base (format nil "session-~d-~d" (get-universal-time)
                      (incf *saved-session-sequence*))))
    (loop for suffix from 1
          for candidate = (if (= suffix 1) base (format nil "~a-~d" base suffix))
          unless (probe-file (saved-session-path candidate)) return candidate)))

(defun session-usage->json (usage)
  (and usage
       (jobj "prompt_tokens" (or (getf usage :prompt-tokens) :null)
             "completion_tokens" (or (getf usage :completion-tokens) :null)
             "total_tokens" (or (getf usage :total-tokens) :null))))

(defun json->session-usage (usage)
  (and (hash-table-p usage)
       (list :prompt-tokens (or (jget usage "prompt_tokens") 0)
             :completion-tokens (or (jget usage "completion_tokens") 0)
             :total-tokens (or (jget usage "total_tokens") 0))))

(defun session-tool-call->json (tool-call)
  (jobj "id" (or (getf tool-call :id) :null)
        "name" (or (getf tool-call :name) :null)
        "arguments" (or (getf tool-call :arguments) (jobj))
        "arguments_error" (or (getf tool-call :arguments-error) :null)))

(defun json->session-tool-call (tool-call)
  (unless (hash-table-p tool-call)
    (error "Saved session contains a non-object tool call"))
  (list :id (jget tool-call "id")
        :name (jget tool-call "name")
        :arguments (or (jget tool-call "arguments") (jobj))
        :arguments-error (jget tool-call "arguments_error")))

(defun session-message->json (message)
  "Serialize one normalized provider message without losing tool arguments."
  (jobj "role" (or (getf message :role) :null)
        "content" (or (getf message :content) :null)
        "tool_call_id" (or (getf message :tool-call-id) :null)
        "tool_calls" (or (mapcar #'session-tool-call->json (getf message :tool-calls))
                         :empty-array)
        "usage" (or (session-usage->json (getf message :usage)) :null)))

(defun json->session-message (message)
  "Deserialize one saved normalized provider message."
  (unless (and (hash-table-p message) (stringp (jget message "role")))
    (error "Saved session contains a message without a string role"))
  (let ((tool-calls (jget message "tool_calls"))
        (usage (json->session-usage (jget message "usage"))))
    (list :role (jget message "role")
          :content (jget message "content")
          :tool-call-id (jget message "tool_call_id")
          :tool-calls (mapcar #'json->session-tool-call (or tool-calls nil))
          :usage usage)))

(defun session-snapshot-record (session name)
  "Return the JSON-ready record persisted by SAVE-SESSION-SNAPSHOT."
  (jobj "format_version" 1
        "name" name
        "saved_at" (get-universal-time)
        "provider" (provider-display-name (session-provider session))
        "model" (provider-model (session-provider session))
        "orchestration_mode" (string-downcase (symbol-name (session-orchestration-mode session)))
        "orchestration_tool_limit" (session-orchestration-tool-limit session)
        "max_tool_iterations" (session-max-tool-iterations session)
        "tool_names" (or (mapcar #'tool-name (session-tools session)) :empty-array)
        "raw_stats" (jobj "requests" (getf (session-raw-stats session) :requests)
                          "tool_calls" (getf (session-raw-stats session) :tool-calls)
                          "prompt_tokens" (getf (session-raw-stats session) :prompt-tokens)
                          "completion_tokens" (getf (session-raw-stats session) :completion-tokens)
                          "total_tokens" (getf (session-raw-stats session) :total-tokens))
        "messages" (or (mapcar #'session-message->json (session-messages session)) :empty-array)))

(defun save-session-snapshot (session &optional name)
  "Write SESSION to a named JSON snapshot and return its record.

When NAME is NIL, generate a timestamped name.  Saving the same explicit name
replaces that snapshot; this makes a named checkpoint convenient to refresh."
  (let* ((snapshot-name (normalize-saved-session-name (or name (next-saved-session-name))))
         (record (session-snapshot-record session snapshot-name))
         (path (saved-session-path snapshot-name)))
    (write-string-atomically path (json-encode record :pretty t))
    record))

(defun read-saved-session (name)
  "Read saved session NAME, validating its minimal versioned JSON envelope."
  (let ((path (saved-session-path name)))
    (unless (probe-file path)
      (error "No saved session named ~s" name))
    (let ((record (with-open-file (in path :direction :input)
                    (json-decode (uiop:slurp-stream-string in)))))
      (unless (and (hash-table-p record) (= (or (jget record "format_version") 0) 1)
                   (listp (jget record "messages")))
        (error "Saved session ~s has an unsupported or invalid format" name))
      record)))

(defun list-saved-sessions ()
  "Return summary records for every readable named saved-session snapshot."
  (ensure-directories-exist (saved-sessions-directory))
  (sort
   (loop for path in (directory (merge-pathnames "*.json" (saved-sessions-directory)))
         for name = (pathname-name path)
         collect
         (handler-case
             (let ((record (read-saved-session name)))
               (list :name (jget record "name")
                     :saved-at (jget record "saved_at")
                     :provider (jget record "provider")
                     :model (jget record "model")
                     :message-count (length (jget record "messages"))))
           (error (condition)
             (list :name name :error (princ-to-string condition)))))
   #'string< :key (lambda (entry) (or (getf entry :name) ""))))

(defun saved-session-mode (record)
  (let ((mode (jget record "orchestration_mode")))
    (unless (member mode '("direct" "plan" "plan-review") :test #'string=)
      (error "Saved session has an invalid orchestration mode"))
    (intern (string-upcase mode) :keyword)))

(defun saved-session-positive-integer (record key fallback)
  (let ((value (jget record key)))
    (if (and (integerp value) (plusp value)) value fallback)))

(defun restore-session-snapshot (session name)
  "Replace SESSION's restorable conversation state from saved session NAME.

The current frontend, provider implementation, and credentials remain live.
The saved model is selected only when it is a string, and saved tool names are
reconciled with tools available in the current image.  Returns two values: the
record and tool names that are no longer available."
  (let* ((record (read-saved-session name))
         (messages (mapcar #'json->session-message (jget record "messages")))
         (catalog (list-tools))
         (saved-tool-names (remove-if-not #'stringp (jget record "tool_names")))
         (available-tools (remove nil (mapcar (lambda (tool-name)
                                                (find tool-name catalog :key #'tool-name :test #'string=))
                                              saved-tool-names)))
         (available-names (mapcar #'tool-name available-tools))
         (missing-tools (remove-if (lambda (tool-name) (member tool-name available-names :test #'string=))
                                   saved-tool-names))
         (stats (jget record "raw_stats")))
    (setf (session-messages session) messages
          (session-tool-catalog session) catalog
          (session-tools session) available-tools
          (session-orchestration-mode session) (saved-session-mode record)
          (session-orchestration-tool-limit session)
          (saved-session-positive-integer record "orchestration_tool_limit" 8)
          (session-max-tool-iterations session)
          (saved-session-positive-integer record "max_tool_iterations" 1000)
          (session-active-plan session) nil
          (session-task-record session) nil
          (session-raw-stats session)
          (list :requests (or (and (hash-table-p stats) (jget stats "requests")) 0)
                :tool-calls (or (and (hash-table-p stats) (jget stats "tool_calls")) 0)
                :prompt-tokens (or (and (hash-table-p stats) (jget stats "prompt_tokens")) 0)
                :completion-tokens (or (and (hash-table-p stats) (jget stats "completion_tokens")) 0)
                :total-tokens (or (and (hash-table-p stats) (jget stats "total_tokens")) 0)))
    (when (stringp (jget record "model"))
      (setf (provider-model (session-provider session)) (jget record "model")))
    (values record missing-tools)))

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
                             (unwind-protect
                                  (progn
                                    (ui-planning-started (session-frontend session))
                                    (plan-user-request session prepared-text))
                               (ui-planning-stopped (session-frontend session)))
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

(defun approximate-token-count (characters)
  "Return a deliberately coarse token estimate for CHARACTERS.

This is for context observability, not billing: tokenizers vary by model and
provider. Four characters per token is a useful display estimate when the
provider has not returned an exact count."
  (ceiling characters 4))

(defun message-context-characters (message)
  "Count the meaningful serialized content of one normalized conversation MESSAGE."
  (+ (length (or (getf message :role) ""))
     (length (or (getf message :content) ""))
     (loop for call in (getf message :tool-calls)
           sum (+ (length (or (getf call :id) ""))
                  (length (or (getf call :name) ""))
                  (length (json-encode (or (getf call :arguments) (jobj))))))))

(defun context-bar (part total)
  "Render PART's relative share of TOTAL as a fixed-width text bar."
  (let* ((width 24)
         (filled (if (plusp total) (round (* width (/ part total))) 0)))
    (format nil "[~a~a]" (make-string filled :initial-element #\#)
            (make-string (- width filled) :initial-element #\.))))

(defun session-context-report (session)
  "Describe the approximate context that the next model request will carry.

The report separates conversation history from advertised tool schemas, which
are both sent to the model. When a provider advertises its capacity, include
the estimated percentage so users can see automatic-compaction headroom."
  (let* ((messages (session-messages session))
         (message-characters (loop for message in messages sum (message-context-characters message)))
         (tool-characters (loop for tool in (session-tools session)
                                sum (length (json-encode (tool-json-schema tool)))))
         (message-tokens (approximate-token-count message-characters))
         (tool-tokens (approximate-token-count tool-characters))
         (total (+ message-tokens tool-tokens))
         (window (provider-context-window (session-provider session)))
         (stats (session-stats-snapshot session)))
    (format nil "Context for the next model request (estimated)~%~%  conversation: ~6d tokens ~a  (~d message~:p)~%  tool schemas: ~6d tokens ~a  (~d tool~:p)~%                    ------~%  total:        ~6d tokens~%~%~a~%Reported session usage: ~d prompt token~:p, ~d completion token~:p across ~d request~:p."
            message-tokens (context-bar message-tokens total) (length messages)
            tool-tokens (context-bar tool-tokens total) (length (session-tools session))
            total
            (if window
                (format nil "Context-window capacity: ~d tokens (~d% used)."
                        window (floor (* 100 (/ total window))))
                "Context-window capacity: not advertised by the active provider/model, so no percentage is shown.")
            (getf stats :prompt-tokens) (getf stats :completion-tokens) (getf stats :requests))))

(defun render-messages-transcript (messages)
  "Render message plists as text for an isolated continuity summarizer."
  (with-output-to-string (out)
    (dolist (message messages)
      (format out "~a: ~a~%"
              (string-upcase (or (getf message :role) "unknown"))
              (or (getf message :content) ""))
      (dolist (call (getf message :tool-calls))
        (format out "ASSISTANT TOOL CALL: ~a ~a~%"
                (getf call :name) (json-encode (getf call :arguments)))))))

(defun session-history-transcript (session)
  "Render SESSION's full history for a user-requested compaction summary."
  (render-messages-transcript (session-messages session)))

(defun compact-session-history (session &key (keep-recent 0))
  "Summarize older history while retaining KEEP-RECENT trailing messages.

The default retains the historical `/compact` behavior: all non-system
conversation messages are summarized.  Automatic compaction supplies a
positive KEEP-RECENT so fresh tool calls and results remain verbatim."
  (unless (and (integerp keep-recent) (not (minusp keep-recent)))
    (error "keep-recent must be a non-negative integer"))
  (let* ((all-messages (session-messages session))
         (initial-system (first all-messages))
         (rest-messages (rest all-messages))
         (recent-count (min keep-recent (length rest-messages)))
         (older-messages (if (plusp recent-count)
                             (subseq rest-messages 0 (- (length rest-messages) recent-count))
                             rest-messages))
         (recent-messages (if (plusp recent-count)
                              (subseq rest-messages (- (length rest-messages) recent-count))
                              nil))
         (before (approximate-token-count
                  (loop for message in all-messages sum (message-context-characters message)))))
    (if (null older-messages)
        (values nil before before)
        (let ((summary
                (session-complete
                 (format nil "Summarize this coding-agent conversation for a future continuation. Preserve the user's goals and constraints, decisions made, files and code changed, exact commands or tool evidence that matter, unresolved work, and the next useful step. Do not address the user, do not add speculation, and do not call tools. Write a concise factual continuity note in plain text.~%~%Conversation:~%~a"
                         (render-messages-transcript older-messages))
                 :system "You compact coding-agent conversation history. Return only a precise continuity summary.")))
          (if (or (null summary) (zerop (length (string-trim " " summary))))
              (values nil before before)
              (progn
                (setf (session-messages session)
                      (list* initial-system
                             (list :role "system"
                                   :content (format nil "[~a]~%~a"
                                                    (if (zerop keep-recent)
                                                        "User-requested context compaction"
                                                        "Context compaction")
                                                    summary))
                             recent-messages))
                (values t before
                        (approximate-token-count
                         (loop for message in (session-messages session)
                               sum (message-context-characters message))))))))))

(defun estimated-context-tokens (session)
  "Estimate tokens sent in SESSION's next provider request."
  (+ (approximate-token-count
      (loop for message in (session-messages session) sum (message-context-characters message)))
     (approximate-token-count
      (loop for tool in (session-tools session)
            sum (length (json-encode (tool-json-schema tool)))))))

(defun count-recent-messages-for-window (session window)
  "Choose a trailing verbatim slice targeting roughly one quarter of WINDOW."
  (let ((target (floor (* window 1/4))) (accumulated 0) (count 0))
    (loop for message in (reverse (session-messages session))
          while (< accumulated target)
          do (incf accumulated (approximate-token-count (message-context-characters message)))
             (incf count))
    count))

(defun auto-compact-if-needed (session)
  "Compact SESSION before a known provider window is exhausted; never signal."
  (let ((threshold (session-context-compaction-threshold session)))
    (when (and (numberp threshold) (plusp threshold) (< threshold 1))
      (let ((window (provider-context-window (session-provider session))))
        (when (and (integerp window) (plusp window)
                   (> (estimated-context-tokens session) (floor (* window threshold))))
          (handler-case
              (multiple-value-bind (compacted-p before after)
                  (compact-session-history
                   session :keep-recent (max 6 (count-recent-messages-for-window session window)))
                (when compacted-p
                  (ui-system (session-frontend session)
                             (format nil "[context] Auto-compacted: ~d -> ~d tokens (window ~d, threshold ~,2F)."
                                     before after window threshold))
                  t))
            (error (condition)
              (ui-system (session-frontend session)
                         (format nil "[context] Auto-compaction attempted but failed: ~a" condition))
              nil)))))))

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
         ;; Roles arrive as freshly decoded strings, so use STRING= rather
         ;; than POSITION's default identity comparison.
         (start (position "user" messages :from-end t :test #'string=
                         :key (lambda (message) (getf message :role))))
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

(defparameter *planned-work-budget-extension-limit* 4
  "Maximum planner-approved extensions for plan-mode and worker turns.

Each approved extension may grant up to 1000 further tool rounds.  This keeps
long-running, evidence-backed work possible without making an accidental tool
loop literally unbounded.")

(defun completion-oriented-budget-p (session)
  "Whether SESSION's budget review should favor finishing scoped work."
  (or (planning-mode-p session) (plusp (session-subagent-depth session))))

(defun parse-tool-budget-review (response max-extra-rounds)
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
                 (and (integerp extra-rounds) (<= 1 extra-rounds max-extra-rounds))))
        (list :decision (intern (string-upcase decision) :keyword)
              :reason reason
              :extra-rounds (if (string= decision "extend") extra-rounds 0))
        (list :decision :finish
              :reason "The tool-budget reviewer returned unusable output; preserving a timely response."
              :extra-rounds 0))))

(defun request-tool-budget-review (session iteration limit assistant-message tool-calls)
  "Ask a tool-free planner whether the model's continuation request should run.

The current assistant reply supplies its stated remaining work and the exact
tool calls it wants next.  In plan mode and workers, the reviewer is biased
toward completing concrete scoped work; direct sessions retain the smaller
anti-loop allowance."
  (let* ((completion-oriented-p (completion-oriented-budget-p session))
         (max-extra-rounds (if completion-oriented-p 1000 3))
         (requested-calls
           (mapcar (lambda (call)
                     (list :name (getf call :name) :arguments (getf call :arguments)))
                   tool-calls)))
  (parse-tool-budget-review
   (session-complete
    (format nil "The agent reached its tool-round limit (~d) at round ~d.~%~%The agent's continuation request:~%Remaining work: ~a~%Requested next tool calls: ~a~%~%Task evidence so far:~%~a"
            limit iteration (or (getf assistant-message :content) "No prose supplied; infer scope from requested calls.")
            (json-encode requested-calls) (current-turn-review-evidence session))
    :system (if completion-oriented-p
                "You are the completion planner for a scoped coding task. The agent has stated remaining work and exact next tool calls. Favor completing the user's task: approve a proportionate extension whenever the calls are concrete, non-repetitive, and plausibly advance the documented plan or produce needed verification. Reject only loops, speculation, or work disconnected from the request. Do not ask the user a question. Reply with JSON only: {\"decision\": \"extend\"|\"finish\", \"reason\": string, \"extra_rounds\": integer}. For extend, grant the number of rounds genuinely needed, from 1 through 1000; for finish use 0."
                "You are a conservative tool-budget reviewer for an agent. Protect the user's time and attention: approve a small extension only when evidence shows concrete progress and a clear, near-term path to materially improve the answer. Do not approve exploratory, repetitive, or speculative work, and do not ask the user a question. If additional work is unlikely to finish promptly, require a timely final answer that states what is known and what remains. Reply with JSON only: {\"decision\": \"extend\"|\"finish\", \"reason\": string, \"extra_rounds\": integer}. For extend, extra_rounds must be 1, 2, or 3; for finish use 0."))
   max-extra-rounds)))

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
  "Validate the isolated shell-command inspector's result.

The inspector remains fail-closed for a genuinely invalid decision, but
accepts an otherwise valid object wrapped in incidental prose or a code fence.
The :VALID-P marker lets INSPECT-SHELL-COMMAND request one format repair
without confusing a malformed response with a substantive rejection."
  (let* ((decoded (handler-case (and (stringp response)
                                     (json-decode (json-object-candidate response)))
                    (error () nil)))
         (decision (jget decoded "decision"))
         (reason (jget decoded "reason"))
         (alternative (jget decoded "alternative"))
         ;; Older inspector responses did not have this field.  Treat its
         ;; absence as NIL so a provider upgrade cannot turn an otherwise
         ;; useful review into a rejection solely because of the new advice.
         (rewritten-command (jget decoded "rewritten_command")))
    (if (and (hash-table-p decoded)
             (member decision '("allow" "reject") :test #'string=)
             (stringp reason)
             (or (null alternative) (stringp alternative))
             (or (null rewritten-command) (stringp rewritten-command)))
        (list :decision (intern (string-upcase decision) :keyword)
              :reason reason :alternative alternative
              :rewritten-command rewritten-command :valid-p t)
        ;; The inspector is a safety boundary: malformed output must not
        ;; silently permit a command whose relevance was never assessed.
        (list :decision :reject
              :reason "The shell-command inspector returned unusable output."
              :alternative "Choose a bounded command with a specific target."
              :rewritten-command nil
              :valid-p nil))))

(defun inspect-shell-command (session command reason result-use)
  "Ask a tool-free reviewer whether COMMAND is a justified shell action.

SESSION supplies the actual task and evidence, while REASON and RESULT-USE
state the proposing model's intended intermediate step.  This keeps the
reviewer from judging a discovery command as though it had to be the final
answer.  It never asks the user for permission."
  (let ((whole-host-reason (whole-host-shell-search-reason command)))
    (if whole-host-reason
        ;; A model cannot override this: whole-host discovery has no bounded
        ;; evidence target, regardless of how confidently it proposes it.
        (list :decision :reject :reason whole-host-reason
              :alternative "Inspect the package manager, language runtime, or another known location."
              :rewritten-command nil)
        (let* ((prompt (format nil "Current task and evidence:~%~a~%~%Why the model needs this command:~%~a~%~%How the model will use the result:~%~a~%~%Proposed shell command:~%~a"
                               (current-turn-review-evidence session) reason result-use command))
               (system "You are a shell-command inspector for a coding agent. Assess the proposed command as an intermediate step toward the user's goal, not as though it must itself be the final answer. The proposing model must state why it needs the command and how it will use the result. Allow bounded, read-only inspection of a specific project file or directory when that stated use plausibly and directly leads to the goal--for example, listing a known source directory to select a code file to read. Reject commands that gather information more broadly than the task/evidence justifies, have an unbounded or poorly targeted search space, duplicate available direct evidence, or whose stated reason or result use is vague, inconsistent, or unlikely to advance the goal. When rejecting, use the stated reason and intended result use to propose one concrete, bounded replacement shell command that would make the same progress; set rewritten_command to null only if no safe command can be inferred. The replacement is advice for the proposing agent and is never executed automatically. This is not a permission check: do not ask the user anything and do not consider authorization. Reply with exactly one JSON object and no surrounding prose: {\"decision\": \"allow\"|\"reject\", \"reason\": string, \"alternative\": string|null, \"rewritten_command\": string|null}."))
          (labels ((review (review-prompt)
                     (let ((*current-session* session))
                       (parse-shell-command-inspection
                        (session-complete review-prompt :system system)))))
            (let ((inspection (review prompt)))
              (if (getf inspection :valid-p)
                  inspection
                  ;; A format-only retry makes an otherwise useful inspector
                  ;; work with providers that prepend prose despite the prompt.
                  (review (format nil "Your preceding response could not be parsed as the required JSON object. Reassess the same command and reply with only the required JSON object, no Markdown or explanation outside it.~%~%~a"
                                  prompt)))))))))

(defun rejected-shell-command-result (inspection)
  "Feedback returned to the model when command inspection rejects a shell call."
  (format nil "Shell command was not run: ~a~@[ Safer next step: ~a~]~@[ Suggested replacement command (review it, then call shell again): ~a~]"
          (getf inspection :reason) (getf inspection :alternative)
          (getf inspection :rewritten-command)))

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
             (inspect-shell-command session
                                    (jget (getf tool-call :arguments) "command")
                                    (jget (getf tool-call :arguments) "reason")
                                    (jget (getf tool-call :arguments) "result_use"))))
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
        (tool-budget-extensions-used 0)
        (tool-budget-finalization-p nil))
    ;; A tool-using turn can make several model requests.  Keep one stable
    ;; activity indicator across the whole turn rather than flashing it off
    ;; after each response and back on for the follow-up request.
    (ui-thinking-started frontend)
    (unwind-protect
         (loop for iteration from 1
          do (auto-compact-if-needed session)
             (let* ((ctx (run-hook-chain :before-request
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
                       ;; This is a code-quality revision, not an answer
                       ;; rejection. Preserve the streamed draft before the
                       ;; follow-up can make a tool call and clear web UI
                       ;; pending text; otherwise the user sees it vanish.
                       (when (getf assistant-message :content)
                         (ui-assistant-text frontend (getf assistant-message :content)))
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
                         ;; Preserve any model narration returned alongside a
                         ;; tool call in richer frontends' activity view. It is
                         ;; progress text the model emitted, not private
                         ;; reasoning, and stays out of the final transcript.
                         (when (getf assistant-message :content)
                           (ui-agent-activity frontend "AGENT NARRATION"
                                              (getf assistant-message :content)))
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
                          (let ((review (if (>= tool-budget-extensions-used
                                                (if (completion-oriented-budget-p session)
                                                    *planned-work-budget-extension-limit* 1))
                                            (list :decision :finish :extra-rounds 0
                                                  :reason "The configured tool-budget extension allowance has been used.")
                                            (request-tool-budget-review session iteration tool-iteration-limit
                                                                        assistant-message tool-calls))))
                            (if (eq (getf review :decision) :extend)
                                (progn
                                  (incf tool-budget-extensions-used)
                                  ;; Include this proposed round, plus the number
                                  ;; of follow-up rounds the completion planner approved.
                                  (incf tool-iteration-limit (1+ (getf review :extra-rounds)))
                                  (ui-system frontend
                                             (format nil "[tool budget] Extension ~d approved through round ~d: ~a"
                                                     tool-budget-extensions-used tool-iteration-limit
                                                     (getf review :reason)))
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

(defclass silent-subagent-frontend (agent-frontend) ())
(defmethod ui-assistant-text ((frontend silent-subagent-frontend) text)
  (declare (ignore frontend text)) (values))
(defmethod ui-system ((frontend silent-subagent-frontend) text)
  (declare (ignore frontend text)) (values))
(defmethod ui-tool-started ((frontend silent-subagent-frontend) tool-name arguments)
  (declare (ignore frontend tool-name arguments)) (values))
(defmethod ui-tool-finished ((frontend silent-subagent-frontend) tool-name arguments result)
  (declare (ignore frontend tool-name arguments result)) (values))

(defun run-subagent (parent task system tools &key (max-tool-iterations 1000) profile)
  "Run one bounded worker and return its final report to PARENT.

Workers have isolated histories and a silent frontend. Their only externally
visible effect is this returned report; nesting is blocked once PARENT reaches
its configured depth limit."
  (when (>= (session-subagent-depth parent) (session-max-subagent-depth parent))
    (return-from run-subagent
      (format nil "Subagent was not started: nesting depth ~d has reached the configured limit."
              (session-max-subagent-depth parent))))
  (let ((selected-profile (and profile (find-subagent-model-profile parent profile))))
    (when (and profile (not selected-profile))
      (return-from run-subagent
        (format nil "Subagent was not started: unknown model profile ~s. Configured profiles: ~{~a~^, ~}."
                profile (mapcar (lambda (entry) (getf entry :name))
                                 (session-subagent-model-profiles parent)))))
    (let* ((profile-limit (and selected-profile (getf selected-profile :max-tool-iterations)))
           (model (or (and selected-profile (getf selected-profile :model))
                      (provider-model (session-provider parent))))
           (profile-system-prompt (and selected-profile (getf selected-profile :system-prompt)))
           (child (make-session (provider-for-model (session-provider parent) model)
                              :frontend (make-instance 'silent-subagent-frontend)
                              :system-prompt (if (and (stringp profile-system-prompt)
                                                      (plusp (length (string-trim " " profile-system-prompt))))
                                                 (format nil "~a~%~%Profile guidance:~%~a"
                                                         system profile-system-prompt)
                                                 system)
                              :tools tools
                              :max-tool-iterations (if (and (integerp profile-limit)
                                                            (plusp profile-limit))
                                                       profile-limit max-tool-iterations)
                              :subagent-depth (1+ (session-subagent-depth parent))
                              :subagent-model-profiles (session-subagent-model-profiles parent)
                              :max-subagent-depth (session-max-subagent-depth parent))))
      (setf (session-messages child)
            (append (session-messages child) (list (list :role "user" :content task))))
      (let ((result (run-agent-turn child)))
        (format nil "Subagent report (depth ~d, model ~a~@[ via profile ~a~], ~d request~:p, ~d tool call~:p):~%~a"
                (session-subagent-depth child)
                model (and selected-profile (getf selected-profile :name))
                (getf (session-raw-stats child) :requests)
                (getf (session-raw-stats child) :tool-calls)
                (or (getf result :content) "The subagent stopped without a final report."))))))

(defun default-explorer-profile (session)
  "Return the configured lightweight explorer profile, if the user supplied one.

The compact (:TOOL MODEL) form is intentionally conventional rather than
mandatory: callers can always pass an explicit profile, while ordinary project
exploration gets the cheaper worker only when the user opted into it."
  (or (find-subagent-model-profile session "tool")
      (find-subagent-model-profile session "explore")))

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
  `(progn
     (setf *slash-commands*
           (cons (cons ,(string-downcase (string name)) (lambda (,session-var ,arg-var) ,@body))
                 (remove ,(string-downcase (string name)) *slash-commands* :key #'car :test #'string=)))
     (publish-component :slash-command ,(string-downcase (string name))
                        :owner (or *registration-owner* "core"))
     ,(string-downcase (string name))))

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

(define-slash-command doctor (session arg)
  "Run local configuration diagnostics without contacting providers or starting services."
  (if (plusp (length (string-trim " " arg)))
      (ui-system (session-frontend session) "Usage: /doctor")
      (ui-system (session-frontend session) (format-doctor-report (run-doctor))))
  t)

(define-slash-command components (session arg)
  "Usage: /components [KIND|ID].  With no argument lists all active
components; a kind (such as tool or hook) filters the list; an ID shows its
complete data-only descriptor."
  (let ((query (string-trim " " arg)))
    (cond
      ((zerop (length query))
       (ui-system (session-frontend session)
                  (format nil "~{~a~^~%~}" (mapcar #'component-summary (list-components)))))
      ((describe-component query)
       (ui-system (session-frontend session)
                  (with-output-to-string (out)
                    (let ((*print-pretty* t))
                      (pprint (component->plist (describe-component query)) out)))))
      (t
       (let ((kind (intern (string-upcase query) :keyword))
             (components nil))
         (setf components (list-components :kind kind))
         (ui-system (session-frontend session)
                    (if components
                        (format nil "~{~a~^~%~}" (mapcar #'component-summary components))
                        (format nil "No active component or component kind named ~s." query)))))))
  t)

(define-slash-command context (session arg)
  "Show the estimated context load for the next model request.

The diagram separates conversation history from the tool schemas currently
offered to the model. It is an estimate because providers use model-specific
tokenizers and do not currently expose their context-window size here."
  (declare (ignore arg))
  (ui-system (session-frontend session) (session-context-report session))
  t)

(define-slash-command compact (session arg)
  "Compact conversation history only when the user explicitly requests it.

This preserves the initial system prompt and replaces the remaining history
with a tool-free continuity summary. It is never invoked automatically."
  (declare (ignore arg))
  (handler-case
      (multiple-value-bind (compacted-p before after) (compact-session-history session)
        (if compacted-p
            (ui-context-compacted (session-frontend session)
                                  (getf (second (session-messages session)) :content)
                                  before after)
            (ui-system (session-frontend session)
                       "Context was not compacted: the summarizer returned no usable continuity note.")))
    (error (c) (ui-error (session-frontend session) c)))
  t)

(defun split-session-command-argument (argument)
  "Return two values: the /SESSION action and its remaining argument."
  (let* ((trimmed (string-trim " " argument))
         (separator (position-if (lambda (character)
                                   (member character '(#\Space #\Tab)))
                                 trimmed)))
    (values (string-downcase (if separator (subseq trimmed 0 separator) trimmed))
            (if separator (string-trim " " (subseq trimmed separator)) ""))))

(defun format-saved-session-list (sessions)
  "Render LIST-SAVED-SESSIONS summaries for every frontend."
  (if sessions
      (format nil "Saved sessions:~%~{~a~^~%~}"
              (mapcar (lambda (entry)
                        (if (getf entry :error)
                            (format nil "  ~a — unreadable: ~a" (getf entry :name) (getf entry :error))
                            (format nil "  ~a — ~d message~:p, ~a / ~a, saved ~a"
                                    (getf entry :name) (getf entry :message-count)
                                    (or (getf entry :provider) "unknown provider")
                                    (or (getf entry :model) "unknown model")
                                    (or (getf entry :saved-at) "unknown time"))))
                      sessions))
      "No saved sessions. Use /session save NAME to create one."))

(define-slash-command session (session arg)
  "Usage: /session save [NAME], /session restore NAME, or /session list.

SAVE writes a named local JSON snapshot (or a generated timestamped name when
NAME is omitted). RESTORE replaces the current conversation and compatible
session settings; LIST displays every saved snapshot."
  (multiple-value-bind (action name) (split-session-command-argument arg)
    (handler-case
        (cond
          ((string= action "save")
           (let ((record (save-session-snapshot session
                                                (and (plusp (length name)) name))))
             (ui-system (session-frontend session)
                        (format nil "Saved session ~a (~d message~:p)."
                                (jget record "name") (length (jget record "messages"))))))
          ((string= action "restore")
           (if (zerop (length name))
               (ui-system (session-frontend session) "Usage: /session restore NAME")
               (multiple-value-bind (record missing-tools)
                   (restore-session-snapshot session name)
                 (ui-stats-updated (session-frontend session) (session-stats-snapshot session))
                 (ui-system (session-frontend session)
                            (format nil "Restored session ~a (~d message~:p)~@[. Unavailable tools were skipped: ~{~a~^, ~}~]."
                                    (jget record "name") (length (jget record "messages"))
                                    missing-tools)))))
          ((string= action "list")
           (when (plusp (length name))
             (error "Usage: /session list"))
           (ui-system (session-frontend session) (format-saved-session-list (list-saved-sessions))))
          (t
           (ui-system (session-frontend session)
                      "Usage: /session save [NAME], /session restore NAME, or /session list.")))
      (error (condition)
        (ui-error (session-frontend session) condition))))
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
