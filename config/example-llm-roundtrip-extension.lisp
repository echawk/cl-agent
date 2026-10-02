;;;; example-llm-roundtrip-extension.lisp -- a worked example of
;;;; SESSION-COMPLETE (src/repl.lisp): a hook (or tool body) getting
;;;; its own, independently-prompted completion from the session's
;;;; own model, instead of just pattern-matching text by hand. Four
;;;; patterns, at the four points in the pipeline where that's useful,
;;;; all real asks:
;;;;
;;;;   1. Rewrite the user's own message before the model ever sees it,
;;;;      via the :USER-MESSAGE chain hook -- here, formalizing slang,
;;;;      but the shape is general: translate it, expand an acronym,
;;;;      anything that should happen before the system prompt or any
;;;;      prior turn is involved.
;;;;   2. Expand the user's message with a synthesized plan, also via
;;;;      :USER-MESSAGE -- here, a one-paragraph outline of which tools
;;;;      to use and in what order, prepended ahead of the original
;;;;      text (not replacing it).
;;;;   3. Transform the assistant's own reply after the fact, via the
;;;;      :AFTER-RESPONSE chain hook -- here, rewritten as a Dr. Seuss-
;;;;      style poem, but the shape is general: translate it, enforce
;;;;      a house style, summarize it, redact something, etc.
;;;;   4. Veto a tool call before it runs, via the :BEFORE-TOOL-CALL
;;;;      chain hook -- here, asking the model itself whether code
;;;;      about to be saved by write-extension has an obvious code
;;;;      smell, and refusing the write (forcing the agent to revise
;;;;      and retry) if it says yes. A :before-tool-call hook that
;;;;      signals an error vetoes the call entirely: the tool never
;;;;      runs, and the error becomes what the model is told (see
;;;;      RUN-TOOL-CALL's docstring in src/repl.lisp).
;;;;
;;;; Every pattern below is off by default (its own *EXAMPLE-...-
;;;; ENABLED* variable starts NIL) -- loading this file wires up all
;;;; four hooks, but none of them do anything until you flip the one
;;;; you want to see, e.g. (setf *example-formalize-enabled* t). That
;;;; way trying one out doesn't mean every reply comes back as a poem
;;;; AND every message gets formalized AND a plan gets prepended, all
;;;; at once.
;;;;
;;;; Copy to ~/.config/cl-agent/extensions/ to try any of these -- see
;;;; the README's "Self-modification" section for the general
;;;; mechanism, and SESSION-COMPLETE's docstring for this one
;;;; specifically.

(in-package :cl-agent)

;; 1. Rewrite slang/casual phrasing out of the user's own message
;; before the model sees it. :USER-MESSAGE fires once per incoming
;; line -- the initial task or a REPL prompt -- before it becomes a
;; "user" role message, so this is the earliest point in the pipeline
;; a hook can act (see hooks.lisp's *HOOK-POINTS*).
(defparameter *example-formalize-enabled* nil)

(add-hook :user-message 'example-formalize
  (lambda (ctx)
    (if (and *example-formalize-enabled* (plusp (length (getf ctx :text))))
        (list :text (or (session-complete
                          (getf ctx :text)
                          :system "Rewrite the user's message to remove slang, contractions, and casual phrasing, in a more formal and polite register, while preserving its exact meaning and intent -- keep any code, commands, filenames, or quoted text byte-for-byte unchanged. Reply with only the rewritten message, nothing else.")
                         (getf ctx :text)))
        ctx)))

;; 2. Prepend a synthesized "what does the user actually want, and
;; which tools should handle it" plan ahead of the original message --
;; expanding it, not replacing it, so the model sees both the plan and
;; the user's own words. Also :USER-MESSAGE, registered independently
;; of EXAMPLE-FORMALIZE above (both can run on the same message; chain
;; hooks compose).
(defparameter *example-user-plan-enabled* nil)

(add-hook :user-message 'example-user-plan
  (lambda (ctx)
    (if (and *example-user-plan-enabled* (plusp (length (getf ctx :text))))
        (list :text
              (format nil "[plan: ~a]~%~%~a"
                      (or (session-complete
                           (getf ctx :text)
                           :system (format nil "You are a planning assistant for a coding agent with these tools available: ~{~a~^, ~}. In 1-2 short sentences, say what the user most likely wants and which tool(s), if any, would accomplish it and in what order. Do not perform the task yourself, and do not ask the user anything -- only plan. If the request is already clear and simple, say so briefly rather than overthinking it."
                                           (mapcar #'tool-name (session-tools *current-session*))))
                          "no plan available")
                      (getf ctx :text)))
        ctx)))

;; 3. Rewrite every assistant reply as a short Dr. Seuss-style poem.
(defparameter *example-seussify-enabled* nil)

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

;; 4. Refuse to let write-extension save code the model itself judges
;; to have an obvious smell. :BEFORE-TOOL-CALL only sees write-
;; extension's raw arguments (a hash table -- see JGET), so this only
;; looks at calls to that one tool and lets everything else through
;; unchanged.
(defparameter *example-reject-smelly-extensions-enabled* nil)

(add-hook :before-tool-call 'example-reject-smelly-extensions
  (lambda (ctx)
    (when (and *example-reject-smelly-extensions-enabled* (string= (getf ctx :tool-name) "write-extension"))
      (let* ((source (jget (getf ctx :arguments) "source"))
             (verdict (and source
                           (session-complete
                            source
                            :system "You are a strict Common Lisp code reviewer. Reply with exactly one word: SMELLY if the code below has an obvious code smell (duplicated logic, a function doing two unrelated things, a magic number that should be a named constant, missing error handling around an operation that can obviously fail, etc), or CLEAN if it doesn't. No other words, no explanation."))))
        (when (and verdict (search "SMELLY" (string-upcase verdict)))
          (error "write-extension rejected: the reviewing model flagged this code as having a smell. Revise it (simpler, one responsibility per function, named constants instead of magic numbers) and call write-extension again."))))
    ctx))
