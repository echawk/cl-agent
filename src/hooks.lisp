;;;; hooks.lisp -- the extension-point mechanism.
;;;;
;;;; This is the lowest-risk way to change cl-agent's behavior: instead
;;;; of redefining an existing function (which can go subtly wrong if
;;;; you mistype something and brick the running image), you ADD a
;;;; function to a named hook. The agent itself (repl.lisp, main.lisp,
;;;; extensions.lisp) calls RUN-HOOK or RUN-HOOK-CHAIN at well-known
;;;; points; see *HOOK-POINTS* below for the full list and what each one
;;;; is for.
;;;;
;;;; There are two kinds of hook, distinguished by which function you
;;;; register them with:
;;;;
;;;;   NOTIFY hooks (add with ADD-HOOK, fire with RUN-HOOK) are for
;;;;   side effects: logging, metrics, sending a desktop notification
;;;;   when a tool call finishes, etc. Every registered function is
;;;;   called with the same arguments; return values are ignored; a
;;;;   signalled error is caught, reported to *error-output*, and does
;;;;   NOT stop the other hook functions or the agent.
;;;;
;;;;   CHAIN hooks (add with ADD-HOOK, fire with RUN-HOOK-CHAIN) are for
;;;;   transforming data as it flows through the agent: rewriting the
;;;;   outgoing message list before it is sent to the provider, rewriting
;;;;   a tool's result before the model sees it, etc. Every chain hook
;;;;   function takes ONE value and must return ONE value (usually a
;;;;   plist); each function's return value becomes the next function's
;;;;   input. A chain hook that raises an error aborts the chain -- the
;;;;   error propagates to the caller -- so be careful.
;;;;
;;;; Example (from an extension file):
;;;;
;;;;   (add-hook :after-tool-call 'log-tool-calls
;;;;     (lambda (ctx)
;;;;       (format *error-output* \"~&[tool] ~a -> ~a chars~%\"
;;;;               (getf ctx :tool-name) (length (getf ctx :result)))
;;;;       ctx))
;;;;
;;;; This is a CHAIN hook (it must return CTX), registered under the
;;;; name 'LOG-TOOL-CALLS so it can later be removed with
;;;; (remove-hook :after-tool-call 'log-tool-calls).

(in-package :cl-agent)

(defparameter *hook-points*
  '((:on-startup . "Fired once, after providers/tools/extensions are all
loaded and before the REPL prompt appears. Notify hook, called with no
arguments. Good place for an extension to print a banner or warm up
some state.")
    (:on-shutdown . "Fired once as the REPL is exiting (including on
Ctrl-D / Ctrl-C). Notify hook, called with no arguments.")
    (:user-message . "Chain hook. Argument/return is a plist (:text
STRING). Fires once per incoming line of user input -- the initial
task, or each REPL prompt -- before it becomes a \"user\" role message
and before :before-request (or the system prompt, or any prior turn)
ever sees it; unlike :before-request, this fires once per user turn,
not once per tool-call round within it. Mutate :text to rewrite or
expand what the model is actually asked -- e.g. rewriting slang into
more formal language, or prepending a synthesized plan of which tools
to use and why -- typically via SESSION-COMPLETE (repl.lisp) to do the
actual rewriting/planning through the model itself, since that's a
judgment call, not a string operation.")
    (:before-request . "Chain hook. Argument/return is a plist
(:messages LIST :tools LIST) about to be sent to the provider. Mutate
or replace either key to change what the model sees on this turn.")
    (:after-response . "Chain hook. Argument/return is the normalized
assistant message plist the provider returned, i.e. (:role \"assistant\"
:content STRING-OR-NIL :tool-calls LIST). Runs before tool calls (if
any) are executed.")
    (:before-tool-call . "Chain hook. Argument/return is a plist
(:tool-name STRING :arguments ALIST). Mutate :arguments to change what
the tool actually receives, or signal an error to veto the call
entirely (the error becomes the tool's result, so the model sees why
it was refused -- see repl.lisp).")
    (:after-tool-call . "Chain hook. Argument/return is a plist
(:tool-name STRING :arguments ALIST :result STRING). Mutate :result to
change what the model is told the tool produced.")
    (:on-error . "Notify hook, called with one argument: the CONDITION
that was signalled and caught by the top-level error handler.")
    (:tool-failure . "Chain hook. Argument/return is a plist describing a tool
call that raised an unhandled ERROR while its stack is still live under
lambda-debugger: (:id RECEIPT-ID :tool-name STRING :arguments HASH :attempt N
:snapshot PLIST :decision NIL). The snapshot holds :condition-type,
:condition-report, :restarts (each with :id and :report) and a bounded
:backtrace. Set :decision to :ABORT (default), :RETRY (repeats the call and its
side effects, capped by *FAILURE-RETRY-LIMIT*), (:RESTART INDEX [\"source\"])
to invoke the INDEXth available restart, or (:RETURN-VALUES \"source\") to
return replacement values; optionally set :decision-note. Errors in a hook
here are recorded and the call is aborted -- they never escape.")
    (:before-subagent-start . "Chain hook. Argument/return is the inert
contract plist for a subagent about to start in a child SBCL (:task :role
:profile :system :provider :tools :max-tool-iterations :max-seconds :depth
:max-depth :setup-forms). Rewrite :system, :tools or :max-seconds, add
:setup-forms, or signal an error to veto the launch. The contract is plain
data; it never carries parent objects.")
    (:after-subagent-result . "Chain hook. Argument/return is a plist
(:task-id ID :status :ok-or-:error :report STRING ...) describing a finished
child's outcome, before the task is settled. Rewrite :report, or change
:status to :error to fail the task.")
    (:subagent-task-transition . "Notify hook, called with a snapshot plist
(:id :state :role :model :tools :note ...) each time a subagent task changes
state (queued, running, succeeded, failed, cancelled, unknown).")
    (:before-extension-load . "Notify hook, called with one argument:
the pathname about to be LOADed by LOAD-EXTENSION-FILE.")
    (:after-extension-load . "Notify hook, called with one argument:
the pathname just successfully LOADed by LOAD-EXTENSION-FILE.")
    (:web-ui-page . "Chain hook. Argument/return is a plist (:html STRING
:safe BOOLEAN): the web UI's page, placeholders already filled, about to be
served. Rewrite :html to inject markup; see ui/web/static/EXTENDING.md.")
    (:web-ui-state . "Chain hook. Argument/return is the hash table GET
/api/state is about to serve the web UI. Add keys for a plugin to read from
CLAgent.state.")
    (:web-ui-asset-changed . "Notify hook, called with one argument: the
path (e.g. \"theme.css\") of a web UI asset that was written, reset, or
changed on disk while a web page was being served.")
    (:working-directory-changed . "Notify hook, called with the old and the
new directory (pathnames) when SET-WORKING-DIRECTORY (/cd, the Code tab, the
set-working-directory tool) changes the directory the shell, file and LSP
tools work in.")
    (:file-opened . "Notify hook, called with the file's namestring when the
Code tab first opens a file in the hosted Lem (lem/files.lisp). Lem's own
*FIND-FILE-HOOK* and the mode's hooks have run by then.")
    (:before-file-save . "Chain hook. Argument/return is a plist (:path
NAMESTRING :text STRING) for a file about to be saved from the Code tab
(C-x C-s). Rewrite :text (a formatter, a license header) or signal an error
to refuse the save. Lem's own before-save-hook still runs after.")
    (:after-file-save . "Notify hook, called with the namestring of a file the
Code tab just saved through Lem.")
    (:file-written . "Notify hook, called with a file's namestring and who
wrote it (\"user\" from the Code tab, \"agent\" from write-file /
edit-file) after it changes on disk. Open editor buffers on it are read
again (or warned, when they have unsaved changes).")
    (:file-closed . "Notify hook, called with the namestring of a file whose
editor buffer was closed."))
  "Documentation table of every hook point the core agent fires.
This is read by the `list-hooks` introspection and by /hooks in the
REPL; it is not itself part of the dispatch mechanism (see
*HOOKS* / ADD-HOOK / RUN-HOOK), so declaring a new hook point here is
optional, but doing so helps anyone (or anything) extending the agent
discover what is available without reading the whole source tree.")

(defvar *hooks* (make-hash-table :test 'eq)
  "Hash table: hook-point keyword -> alist of (name . function).
Functions run in registration order (oldest first) unless :append nil
was passed to ADD-HOOK, in which case the function is pushed to the
front instead.")

(dolist (hook-point *hook-points*)
  (publish-component :hook-point (car hook-point)
                     :metadata (list :description (cdr hook-point))))

(declaim (ftype (function (symbol t (or function symbol) &key (:append t)) (values t &optional)) add-hook))
(defun add-hook (hook-point name function &key (append t))
  "Register FUNCTION under NAME (any EQL-comparable designator, usually
a symbol or keyword -- re-adding the same NAME replaces the previous
function rather than stacking a duplicate) on HOOK-POINT. By default
the function is appended (runs after previously-registered functions);
pass :APPEND NIL to run it first instead."
  (let* ((existing (gethash hook-point *hooks*))
         (without (remove name existing :key #'car :test #'eql)))
    (setf (gethash hook-point *hooks*)
          (if append
              (append without (list (cons name function)))
              (cons (cons name function) without)))
    (publish-component :hook (format nil "~(~a~)/~(~a~)" hook-point name)
                       :owner (or *registration-owner* "core")
                       :requires (list (component-id :hook-point hook-point))
                       :metadata (list :hook-point hook-point
                                       :order (position name (mapcar #'car (gethash hook-point *hooks*))
                                                        :test #'eql))))
  name)

(defun remove-hook (hook-point name)
  "Unregister the function previously added under NAME on HOOK-POINT.
Returns T if something was removed, NIL if NAME was not registered."
  (let ((existing (gethash hook-point *hooks*)))
    (if (assoc name existing :test #'eql)
        (progn (setf (gethash hook-point *hooks*)
                     (remove name existing :key #'car :test #'eql))
               (unpublish-component :hook (format nil "~(~a~)/~(~a~)" hook-point name))
               t)
        nil)))

(defun clear-hooks (&optional hook-point)
  "Remove all hook functions for HOOK-POINT, or for every hook point if
HOOK-POINT is not supplied. Mostly useful for tests."
  (if hook-point
      (remhash hook-point *hooks*)
      (clrhash *hooks*)))

(defun list-hooks (&optional hook-point)
  "Return an alist of (hook-point . (name...)) describing what is
currently registered, or just the list of names for HOOK-POINT if
supplied."
  (if hook-point
      (mapcar #'car (gethash hook-point *hooks*))
      (loop for point being the hash-keys of *hooks* using (hash-value fns)
            collect (cons point (mapcar #'car fns)))))

(defun record-hook-execution (kind hook-point name &key parent-id condition)
  "Append a small session receipt for one hook invocation when applicable.

Hook inputs and outputs can contain credentials, full prompts, or arbitrary
extension objects, so the durable receipt deliberately records identity and
outcome only.  The surrounding request/tool event already records the safe
protocol data needed for replay."
  (when *current-session*
    (record-session-event *current-session* kind
                          :parent-id parent-id
                          :component (format nil "hook:~(~a~)/~(~a~)" hook-point name)
                          :status (if condition "failed" "finished")
                          :payload (list :hook-point hook-point :hook-name (string name)
                                         :detail (and condition (princ-to-string condition))))))

;;; A hook is an extension's code -- often the agent's own, written
;;; minutes ago -- run in the middle of a turn.  So no hook can take the
;;; agent down: a failing one (any SERIOUS-CONDITION, stack exhaustion too)
;;; is recorded, reported and skipped, the value going on unchanged; a
;;; chain hook returning the wrong kind of value (not the plist it was
;;; given, say) counts as failing; and a hook that fails
;;; *HOOK-FAILURE-LIMIT* times in a row is switched off until its extension
;;; is loaded again.  Only the veto points -- :before-tool-call,
;;; :before-subagent-start (and :tool-failure, whose caller records it) --
;;; let an error through, to their callers, who turn it into a refusal.
;;; A plist is handed to each hook as a copy, so one that changes it and
;;; then fails leaves nothing behind.

(defparameter *hook-failure-limit* 3
  "Failures in a row after which a hook is switched off.")

(defparameter *hook-seconds* 120
  "The longest one hook may run before it counts as failing.")

(defvar *hook-failures* (make-hash-table :test 'equal)
  "(hook-point . name) -> failures in a row.")

(declaim (ftype (function (t) (values boolean &optional)) plist-shaped-p))
(defun plist-shaped-p (value)
  (and (listp value)
       (handler-case (and (evenp (list-length value))
                          (loop for (key) on value by #'cddr always (keywordp key)))
         (error () nil))))

(declaim (ftype (function (t) (values (member :hash-table :string :plist :other) &optional)) hook-value-kind))
(defun hook-value-kind (value)
  (cond ((hash-table-p value) :hash-table)
        ((stringp value) :string)
        ((and value (plist-shaped-p value)) :plist)
        (t :other)))

(defun note-hook-success (hook-point name)
  (remhash (cons hook-point name) *hook-failures*))

(declaim (ftype (function (symbol t (or condition string)) (values t &optional)) note-hook-failure))
(defun note-hook-failure (hook-point name problem)
  "Report that hook NAME on HOOK-POINT failed with PROBLEM (a condition or
text), and switch it off after too many failures in a row."
  (let* ((key (cons hook-point name))
         (count (setf (gethash key *hook-failures*) (1+ (gethash key *hook-failures* 0))))
         (disable (>= count *hook-failure-limit*))
         (text (format nil "[hook ~(~a~)/~(~a~)] failed: ~a~:[~;~%  Switched off after ~d failures in a row; fix the extension that adds it and load it again.~]"
                       hook-point name (first-line (princ-to-string problem) 300) disable count)))
    (when disable
      (remhash key *hook-failures*)
      (remove-hook hook-point name))
    (ignore-errors (format *error-output* "~&~a~%" text))
    ;; The person (and, in the transcript, the model) sees it too.
    (ignore-errors
     (when (and (boundp '*current-session*) (symbol-value '*current-session*))
       (ui-system (session-frontend (symbol-value '*current-session*)) text)))))

(declaim (ftype (function (symbol &rest t) (values &optional)) run-hook))
(defun run-hook (hook-point &rest args)
  "Call every NOTIFY hook function registered on HOOK-POINT with ARGS,
in registration order.  Return values are ignored.  A function that
fails is reported and skipped (see above); it never reaches the caller."
  (dolist (entry (gethash hook-point *hooks*))
    (let* ((intent (ignore-errors (record-hook-execution :hook-started hook-point (car entry))))
           (failure (call-hook-contained hook-point (car entry)
                                         (lambda () (apply (cdr entry) args) nil))))
      (cond ((null failure)
             (note-hook-success hook-point (car entry))
             (ignore-errors (record-hook-execution :hook-finished hook-point (car entry)
                                                   :parent-id (and intent (getf intent :id)))))
            (t
             (ignore-errors (record-hook-execution :hook-failed hook-point (car entry)
                                                   :parent-id (and intent (getf intent :id)) :condition failure))
             (note-hook-failure hook-point (car entry) failure)))))
  (values))

(declaim (ftype (function (symbol t function) (values (or null condition) t &optional)) call-hook-contained))
(defun call-hook-contained (hook-point name thunk)
  "Call THUNK, a hook's work, as agent code with a time limit.  Returns
NIL and THUNK's value when it returned; else the condition that stopped it
-- whatever it signalled (but a real Ctrl-C), or AGENT-ESCAPE for a
non-local exit (guard.lisp)."
  (let ((value nil))
    (values
     (with-contained-exits (:on-escape (make-condition 'agent-escape
                                                       :where (format nil "The ~(~s~) hook ~(~a~)" hook-point name)))
       (block call
         (handler-bind ((serious-condition
                          (lambda (c) (unless (person-interrupt-p c) (return-from call c)))))
           (setf value (unwind-protect (with-agent-code () (sb-ext:with-timeout *hook-seconds* (funcall thunk)))
                         (reassert-guards)))
           nil)))
     value)))

(defparameter *veto-hook-points* '(:before-tool-call :before-subagent-start :tool-failure)
  "Chain hook points whose callers take a hook's error themselves: a veto
for the first two, a decision not made for :tool-failure.")

(declaim (ftype (function (symbol t) (values t &optional)) run-hook-chain))
(defun run-hook-chain (hook-point value)
  "Thread VALUE through every CHAIN hook function registered on
HOOK-POINT, in registration order: each function receives the previous
function's return value and must return the (possibly new) value for
the next one.  Returns the final value.  A hook that fails, or returns a
different kind of value than it was given, is reported and skipped (see
above), the value going on as it was -- except at the veto points
(*VETO-HOOK-POINTS*), where an error goes to the caller as a refusal."
  (dolist (entry (gethash hook-point *hooks*) value)
    (let ((intent (ignore-errors (record-hook-execution :hook-started hook-point (car entry))))
          (veto-p (member hook-point *veto-hook-points*)))
      (let ((kind (hook-value-kind value)))
        (multiple-value-bind (condition new)
            (call-hook-contained hook-point (car entry)
                                 (lambda () (funcall (cdr entry) (if (eq kind :plist) (copy-list value) value))))
          (cond
            (condition
             (ignore-errors (record-hook-execution :hook-failed hook-point (car entry)
                                                   :parent-id (and intent (getf intent :id)) :condition condition))
             (if veto-p
                 (error condition)
                 (note-hook-failure hook-point (car entry) condition)))
            ((and (not (eq kind :other)) (not (eq (hook-value-kind new) kind)))
             (ignore-errors (record-hook-execution :hook-failed hook-point (car entry)
                                                   :parent-id (and intent (getf intent :id))))
             (note-hook-failure hook-point (car entry)
                                (format nil "it returned ~a instead of the ~(~a~) it was given (a chain hook returns its argument, changed or not)"
                                        (or (ignore-errors (let ((*print-length* 4) (*print-level* 2)) (prin1-to-string new)))
                                            "an unprintable value")
                                        kind)))
            (t
             (setf value new)
             (note-hook-success hook-point (car entry))
             (ignore-errors (record-hook-execution :hook-finished hook-point (car entry)
                                                   :parent-id (and intent (getf intent :id)))))))))))
