;;;; tools/extensions-tool.lisp -- exposes extensions.lisp to the model
;;;; itself, via two tools:
;;;;
;;;;   eval-lisp         ephemeral: evaluate a form in the running
;;;;                      image right now, see the result, nothing
;;;;                      persists past this process exiting. Good for
;;;;                      the agent to inspect its own state
;;;;                      (list-tools, list-hooks, apropos...) or try
;;;;                      an idea before committing it to a file.
;;;;
;;;;   write-extension   persistent: write a named file of Lisp source
;;;;                      under ~/.config/cl-agent/extensions/, then
;;;;                      (by default) load it into this image AND
;;;;                      enable it so it loads again on every future
;;;;                      start. This is the tool that actually lets
;;;;                      the agent upgrade itself across sessions.
;;;;
;;;; These two tools together are the "unique feature": because the
;;;; model can call eval-lisp to test an approach and then
;;;; write-extension to keep it, the user can ask the agent to improve
;;;; or extend itself in plain English and have that improvement
;;;; survive a restart, entirely from inside the conversation.

(in-package :cl-agent)

(define-tool eval-lisp (args)
    (:description "Evaluate a Common Lisp form in the running agent's own image and return its printed result. Ephemeral: has full read/write access to the agent's own state (hooks, tools, providers, everything in the :cl-agent package) but is NOT saved -- it is gone if the process restarts. Use this to inspect current state (e.g. (list-tools), (list-hooks)) or to try something out before persisting it with the write-extension tool. The form is read with *package* bound to :cl-agent, so bare symbol names (chat, define-tool, add-hook, ...) resolve there."
     :parameters (jobj "type" "object"
                        "properties" (jobj "form" (jobj "type" "string"
                                                         "description" "A single Lisp form, as text, e.g. \"(list-tools)\"."))
                        "required" (list "form")))
  (let* ((text (jget args "form"))
         (imbalance (check-paren-balance text)))
    (if imbalance
        (paren-imbalance-message imbalance)
        (handler-case
            (let* ((*package* (find-package :cl-agent))
                   (*read-eval* nil)
                   (form (read-from-string text)))
              (format nil "~{~a~^~%~}"
                      (mapcar #'prin1-to-string (multiple-value-list (eval form)))))
          (error (c) (format nil "Error: ~a" c))))))

(defun paren-imbalance-message (imbalance)
  "Turn a CHECK-PAREN-BALANCE result into a message telling the model
specifically what to fix, rather than a bare reader end-of-file error."
  (let ((n (getf imbalance :open-count)) (line (getf imbalance :line)))
    (if (plusp n)
        (format nil "Unbalanced parentheses: ~d unclosed \"(\" (last opened/closed around line ~d). Add ~:*~d more \")\" and try again."
                n line)
        (format nil "Unbalanced parentheses: ~d extra \")\" with no matching \"(\" (around line ~d). Remove ~:*~d \")\" and try again."
                (- n) line))))

(define-tool write-extension (args)
    (:description "Write a named file of Common Lisp source code to the agent's own extensions directory (~/.config/cl-agent/extensions/), load it into the running image, and (unless told not to) enable it so it is automatically loaded on every future start -- this is how you permanently add a tool, a hook callback, a provider, or change the agent's own behavior. The file MUST start with (in-package :cl-agent). Prefer ADDING things (new DEFINE-TOOL forms, new ADD-HOOK calls, new DEFMETHODs on existing generic functions) over redefining existing functions from scratch, since a mistake in a wholesale redefinition can break the running agent until the file is fixed or disabled. If `load` is true and loading fails, the file is still written to disk (so it isn't lost) but NOT enabled, and the error is returned so it can be fixed and retried."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "filename" (jobj "type" "string" "description" "Bare filename, e.g. \"word-count-tool.lisp\" (the .lisp suffix is added if missing). Reuse an existing filename to overwrite/update that extension.")
                 "source" (jobj "type" "string" "description" "Full Lisp source of the file, starting with (in-package :cl-agent).")
                 "load" (jobj "type" "boolean" "description" "Load the file into the running image immediately. Default true.")
                 "enable" (jobj "type" "boolean" "description" "Enable the file to auto-load on future starts (only takes effect if load succeeds). Default true."))
           "required" (list "filename" "source")))
  (let* ((filename (jget args "filename"))
         (source (jget args "source"))
         (bare (if (search ".lisp" filename :from-end t) filename (concatenate 'string filename ".lisp")))
         ;; JSON false decodes to Lisp NIL (see json-util.lisp), which JGET
         ;; correctly distinguishes from "argument absent" via its
         ;; DEFAULT (T here) -- so a bare (not (null v)) is the right test.
         (do-load (not (null (jget args "load" t))))
         (do-enable (not (null (jget args "enable" t))))
         (imbalance (check-paren-balance source)))
    (if imbalance
        (format nil "Not written -- ~a" (paren-imbalance-message imbalance))
        (let ((path (write-extension-file filename source)))
          (if do-load
              (handler-case
                  (progn
                    (load-extension-file path)
                    (when do-enable (set-extension-enabled bare t))
                    (format nil "Wrote and loaded ~a~:[ (not enabled for future sessions)~;, enabled for future sessions~]."
                            path do-enable))
                (extension-error (c)
                  (format nil "Wrote ~a but it failed to load, so it was NOT enabled:~%~a~%~
                                Fix the error and call write-extension again with the same filename to retry."
                           path c)))
              (format nil "Wrote ~a (not loaded or enabled; pass load=true to activate it)." path))))))
