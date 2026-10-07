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
    (:before-extension-load . "Notify hook, called with one argument:
the pathname about to be LOADed by LOAD-EXTENSION-FILE.")
    (:after-extension-load . "Notify hook, called with one argument:
the pathname just successfully LOADed by LOAD-EXTENSION-FILE."))
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

(defun run-hook (hook-point &rest args)
  "Call every NOTIFY hook function registered on HOOK-POINT with ARGS,
in registration order. Return values are ignored. A function that
signals an error is reported to *ERROR-OUTPUT* and skipped; it does
not stop the remaining hook functions or propagate to the caller, so a
buggy extension cannot take down the agent from a notify hook."
  (dolist (entry (gethash hook-point *hooks*))
    (handler-case (apply (cdr entry) args)
      (error (c)
        (format *error-output* "~&[hook ~a/~a] error: ~a~%"
                hook-point (car entry) c))))
  (values))

(defun run-hook-chain (hook-point value)
  "Thread VALUE through every CHAIN hook function registered on
HOOK-POINT, in registration order: each function receives the previous
function's return value and must return the (possibly new) value for
the next one. Returns the final value. Unlike RUN-HOOK, an error here
propagates to the caller -- a chain hook is in the critical path of a
request, so silently swallowing its failure could hide a real bug in
an extension that the agent (or its author) needs to see."
  (dolist (entry (gethash hook-point *hooks*) value)
    (setf value (funcall (cdr entry) value))))
