;;;; example-llm-roundtrip-extension.lisp -- a worked example of
;;;; SESSION-COMPLETE (src/repl.lisp): a hook (or tool body) getting
;;;; its own, independently-prompted completion from the session's
;;;; own model, instead of just pattern-matching text by hand. Two
;;;; patterns, both real asks:
;;;;
;;;;   1. Transform the assistant's own reply after the fact, via the
;;;;      :AFTER-RESPONSE chain hook -- here, rewritten as a Dr. Seuss-
;;;;      style poem, but the shape is general: translate it, enforce
;;;;      a house style, summarize it, redact something, etc.
;;;;   2. Veto a tool call before it runs, via the :BEFORE-TOOL-CALL
;;;;      chain hook -- here, asking the model itself whether code
;;;;      about to be saved by write-extension has an obvious code
;;;;      smell, and refusing the write (forcing the agent to revise
;;;;      and retry) if it says yes. A :before-tool-call hook that
;;;;      signals an error vetoes the call entirely: the tool never
;;;;      runs, and the error becomes what the model is told (see
;;;;      RUN-TOOL-CALL's docstring in src/repl.lisp).
;;;;
;;;; Copy to ~/.config/cl-agent/extensions/ to try either (or both) --
;;;; see the README's "Self-modification" section for the general
;;;; mechanism, and SESSION-COMPLETE's docstring for this one
;;;; specifically.

(in-package :cl-agent)

;; 1. Rewrite every assistant reply as a short Dr. Seuss-style poem.
;; A DEFPARAMETER, not a hardcoded T, so it's easy to turn off again
;; without removing the hook: (setf *example-seussify-enabled* nil).
(defparameter *example-seussify-enabled* t)

(add-hook :after-response 'example-seussify
  (lambda (message)
    (when (and *example-seussify-enabled* (getf message :content))
      (setf (getf message :content)
            (or (session-complete
                 (getf message :content)
                 :system "Rewrite the text below as a short, playful Dr. Seuss-style rhyming poem. Keep its meaning and any facts, code, filenames, or numbers exactly as given -- don't invent or drop information, just change the voice.")
                ;; A failed/empty rewrite keeps the original text rather
                ;; than losing the reply entirely.
                (getf message :content))))
    message))

;; 2. Refuse to let write-extension save code the model itself judges
;; to have an obvious smell. :BEFORE-TOOL-CALL only sees write-
;; extension's raw arguments (a hash table -- see JGET), so this only
;; looks at calls to that one tool and lets everything else through
;; unchanged.
(add-hook :before-tool-call 'example-reject-smelly-extensions
  (lambda (ctx)
    (when (string= (getf ctx :tool-name) "write-extension")
      (let* ((source (jget (getf ctx :arguments) "source"))
             (verdict (and source
                           (session-complete
                            source
                            :system "You are a strict Common Lisp code reviewer. Reply with exactly one word: SMELLY if the code below has an obvious code smell (duplicated logic, a function doing two unrelated things, a magic number that should be a named constant, missing error handling around an operation that can obviously fail, etc), or CLEAN if it doesn't. No other words, no explanation."))))
        (when (and verdict (search "SMELLY" (string-upcase verdict)))
          (error "write-extension rejected: the reviewing model flagged this code as having a smell. Revise it (simpler, one responsibility per function, named constants instead of magic numbers) and call write-extension again."))))
    ctx))
