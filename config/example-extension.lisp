;;;; example-extension.lisp -- a worked example of the self-modification
;;;; surface described in src/extensions.lisp, src/hooks.lisp, and
;;;; src/tools.lisp. Copy this to ~/.config/cl-agent/extensions/ (or
;;;; have the agent do it for you with the write-extension tool -- see
;;;; the README's "Self-modification" section) to try it out.
;;;;
;;;; It demonstrates the three things an extension typically does:
;;;;   1. add a new tool (DEFINE-TOOL)
;;;;   2. hang a side effect off an existing hook point (ADD-HOOK)
;;;;   3. add a new REPL slash command (DEFINE-SLASH-COMMAND)
;;;; none of which require touching a single line of the core agent.

(in-package :cl-agent)

;; 1. A new tool: count words in a string.
(define-tool word-count (args)
    (:description "Count words in a string."
     :parameters (jobj "type" "object"
                        "properties" (jobj "text" (jobj "type" "string" "description" "Text to count words in."))
                        "required" (list "text")))
  (format nil "~d words" (length (uiop:split-string (jget args "text")))))

;; 2. Log every tool call to *error-output* (visible in the terminal,
;; not sent to the model) -- a CHAIN hook that returns CTX unchanged
;; after its side effect.
(add-hook :after-tool-call 'example-extension-log-tool-calls
  (lambda (ctx)
    (format *error-output* "~&[example-extension] ~a(~a) -> ~d chars~%"
            (getf ctx :tool-name) (getf ctx :arguments) (length (getf ctx :result)))
    ctx))

;; 3. /wc as a shorthand: count words in the rest of the line, without
;; going through the model at all.
(define-slash-command wc (session arg)
  (declare (ignore session))
  (format t "~&~d words~%" (length (uiop:split-string arg)))
  t)
