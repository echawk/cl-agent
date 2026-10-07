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
;;;;   write-scratch-file non-executing: save a temporary artifact under
;;;;                      ~/.config/cl-agent/scratch/ for the user or a
;;;;                      later deliberate command to use.
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

(define-tool write-scratch-file (args)
    (:description "Save arbitrary text as a non-executing scratch artifact under ~/.config/cl-agent/scratch/. Use this for draft programs, one-off test files, code the user asked to receive, or any temporary file. It never compiles, loads, enables, or evaluates the contents. Filename must be a bare filename, not a path. Do NOT use write-extension as scratch space: write-extension is only for a durable change to cl-agent itself."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "filename" (jobj "type" "string" "description" "Bare filename such as \"experiment.lisp\" or \"answer.txt\"; directories are not allowed.")
                 "contents" (jobj "type" "string" "description" "Exact text to save. It can be any language or plain text."))
           "required" (list "filename" "contents")))
  (let ((filename (jget args "filename"))
        (contents (jget args "contents")))
    (handler-case
        (let ((path (write-scratch-file filename contents)))
          (format nil "Saved scratch artifact ~a. It was not compiled, loaded, enabled, or evaluated." path))
      (error (c)
        (format nil "Scratch artifact was not saved: ~a" c)))))

(define-tool eval-lisp (args)
    (:description "Evaluate a Common Lisp form in the running agent's own image and return its printed result. Before evaluation, the form is automatically reviewed with Mallet, checked for DEFSTAR/DECLAIM type claims on definitions, and compiled; compilation failures prevent evaluation while advisory smells are returned with the value so you can improve the code. Ephemeral: has full read/write access to the agent's own state but is not saved. The form is read with *package* bound to :cl-agent."
     :parameters (jobj "type" "object"
                        "properties" (jobj "form" (jobj "type" "string"
                                                         "description" "A single Lisp form, as text, e.g. \"(list-tools)\"."))
                        "required" (list "form")))
  (let* ((text (jget args "form"))
         (imbalance (check-paren-balance text)))
    (if imbalance
        (paren-imbalance-message imbalance)
        (let* ((compilable-source (format nil "(in-package :cl-agent)~%~a~%" text))
               (review (review-lisp-source compilable-source)))
          (if (getf review :compile-failure-p)
              (format nil "Not evaluated because compilation failed.~%~a"
                      (format-lisp-review review))
              (handler-case
                  (let* ((*package* (find-package :cl-agent))
                         (*read-eval* nil)
                         (form (read-from-string text))
                         (value-text
                           (format nil "~{~a~^~%~}"
                                   (mapcar #'prin1-to-string
                                           (multiple-value-list (eval form))))))
                    (format nil "~a~%~%~a" value-text (format-lisp-review review)))
                (error (c) (format nil "Error: ~a~%~%~a" c (format-lisp-review review)))))))))

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
    (:description "Write a named Common Lisp extension, load it, and optionally enable it for future starts. This is exclusively for a durable change to cl-agent itself: the source must integrate a tool, hook, method, provider, frontend, or slash command. It is NOT a scratchpad or a way to run ordinary programs/tests; use write-scratch-file for those. Source is automatically reviewed with strict Mallet, checked for a DEFSTAR or DECLAIM FTYPE claim on every function, and compiled first. Compilation failures are reported and are not written; nonzero smell scores are advisory and are returned after a successful write so you can minimize them. The file MUST start with (in-package :cl-agent). Prefer adding definitions/hooks/methods over replacing core functions."
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
    (cond
      (imbalance
        (format nil "Not written -- ~a" (paren-imbalance-message imbalance)))
      ((not (extension-source-integrates-p source))
       "Not written: this source does not add a durable cl-agent integration. Use write-scratch-file for a program, experiment, test, or draft; reserve write-extension for a tool, hook, method, provider, frontend, or slash command.")
      (t
       (handler-case
           (let ((transaction (propose-extension filename source)))
             (preflight-mutation transaction)
             (if do-load
                 (progn
                   (install-mutation transaction)
                   (exercise-mutation transaction)
                   (commit-mutation transaction :enable-p do-enable)
                   (format nil "Committed mutation ~a: staged, preflighted, installed, exercised, and published ~a~:[ (not enabled for future sessions)~;, enabled for future sessions~]."
                           (mutation-id transaction) (mutation-target transaction) do-enable))
                 ;; Compatibility mode: the user explicitly requested a saved
                 ;; but inactive draft, so publish source only and retain its
                 ;; proposal receipt for later inspection.
                 (progn
                   (write-extension-file bare source)
                   (format nil "Wrote inactive extension draft ~a (mutation ~a; not loaded or enabled)."
                           bare (mutation-id transaction)))))
         (error (condition)
           (format nil "Extension mutation was not committed: ~a" condition)))))))
