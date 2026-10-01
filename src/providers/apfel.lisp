;;;; providers/apfel.lisp -- Apple's on-device model (Apple
;;;; Intelligence / the FoundationModels framework, macOS 26+), via
;;;; apfel (https://apfel.franzai.com, `brew install apfel`), a CLI
;;;; and OpenAI-compatible local HTTP server wrapping that framework.
;;;;
;;;; This used to be a speculative "bring your own bridge executable"
;;;; stub, written before anything like apfel existed, for exactly
;;;; this purpose -- apfel turned out to need none of that: `apfel
;;;; --serve` speaks real OpenAI chat/completions wire format
;;;; (confirmed directly against a running instance: /v1/models,
;;;; /v1/chat/completions, and tool-calling parameters are all there),
;;;; so this is a thin OPENAI-COMPATIBLE-PROVIDER subclass, the same
;;;; shape as providers/ollama.lisp, right down to the same "start the
;;;; local server if it isn't already running" PROVIDER-ENSURE-READY
;;;; pattern (see that file -- this one only differs in the handful of
;;;; apfel-specific details called out below).
;;;;
;;;; Registered under BOTH :apple (the platform) and :apfel (the tool
;;;; name) -- same provider, either name works.
;;;;
;;;; Caveats worth knowing, not worth coding around:
;;;;   - Context window is tiny: 4096 tokens on macOS 26, 8192 on
;;;;     macOS 27+ (input+output combined, per `apfel --model-info`).
;;;;     A long conversation or a big tool result will overflow it.
;;;;   - Tool-calling exists (the model advertises "tools"/"tool_choice"
;;;;     as supported /v1/models parameters) but was observed, in
;;;;     testing, to sometimes have the model emit the tool invocation
;;;;     as plain-text content instead of a structured tool call ("tool
;;;;     policy repair: tool_call_not_allowed" in apfel's own server
;;;;     log) -- the same kind of small/local-model flakiness
;;;;     t/test-ollama-integration.lisp already treats as an accepted,
;;;;     non-fatal outcome rather than a bug to fix here.
;;;;   - Apple's default content guardrails are strict enough to
;;;;     refuse some entirely ordinary prompts outright ("I cannot
;;;;     respond to that."); APFEL-EXTRA-ARGS below is how to pass
;;;;     apfel's own --permissive flag through if that's a problem for
;;;;     your use, see also apfel's own --help.

(in-package :cl-agent)

(defclass apfel-provider (openai-compatible-provider)
  ((extra-args :initarg :extra-args :initform nil :accessor apfel-extra-args
               :documentation "Extra CLI arguments appended to `apfel
--serve ...` when PROVIDER-ENSURE-READY starts it, e.g. (\"--permissive\")
or (\"--context-strategy\" \"summarize\"). See `apfel --help`."))
  (:default-initargs :base-url "http://127.0.0.1:11535/v1")
  (:documentation "Apple Intelligence via a local `apfel --serve`
instance. No API key. The default port, 11535, is deliberately NOT
apfel's own CLI default (11434, the same as Ollama's) -- picking a
distinct port means cl-agent starting its own apfel server can never
collide with an already-running Ollama (or a separately, manually
started apfel) on the standard port; see PROVIDER-ENSURE-READY."))

(defmethod provider-default-model ((provider apfel-provider)) "apple-foundationmodel")
(defmethod provider-display-name ((provider apfel-provider)) "Apple Intelligence (apfel)")
;; Deliberately no PROVIDER-API-KEY-ENV-VAR method: local, no key needed.

(defparameter *apfel-start-timeout* 20
  "Seconds PROVIDER-ENSURE-READY will wait for a just-started `apfel
--serve` to become reachable before giving up.")

(defun apfel-root (provider)
  "Strip PROVIDER-BASE-URL's /v1 suffix to get apfel's own endpoints
(/health, /v1/models' sibling) -- same idea as OLLAMA-API-ROOT."
  (let ((base (provider-base-url provider)))
    (if (and (>= (length base) 3) (string= base "/v1" :start1 (- (length base) 3)))
        (subseq base 0 (- (length base) 3))
        base)))

(defun apfel-port (provider)
  "Extract the port number from PROVIDER-BASE-URL (e.g. \"http://127.0.0.1:11535/v1\"
-> 11535), to pass as `apfel --serve --port ...` -- apfel has no way to
discover \"whatever port the caller's base-url says\" itself."
  (let* ((root (apfel-root provider))
         (colon (position #\: root :from-end t))
         (digits (subseq root (1+ colon))))
    (parse-integer digits :junk-allowed t)))

(defun apfel-health (provider)
  "NIL if unreachable; otherwise the decoded JSON /health body (a hash
table with \"status\", \"model_available\", ... -- see this file's
header comment for what an instance reports)."
  (handler-case
      (multiple-value-bind (body status)
          (drakma:http-request (concatenate 'string (apfel-root provider) "/health") :connection-timeout 2)
        (and (= status 200) (json-decode (if (stringp body) body (flexi-streams:octets-to-string body :external-format :utf-8)))))
    (error () nil)))

(defun start-apfel-server (provider)
  "Launch `apfel --serve --port PORT` (plus PROVIDER's APFEL-EXTRA-ARGS)
as a detached background process, logging to ~/.config/cl-agent/apfel-
serve.log for the same reason START-OLLAMA-SERVER does (providers/
ollama.lisp): keep it out of whatever UI frontend is active, but
inspectable. Returns T if launched, NIL if no `apfel` executable is on
PATH."
  (let ((apfel (find-executable-on-path "apfel")))
    (when apfel
      (ensure-config-directory)
      (let ((log (merge-pathnames "apfel-serve.log" *config-directory*)))
        ;; :IF-OUTPUT-EXISTS/:IF-ERROR-OUTPUT-EXISTS left at LAUNCH-
        ;; PROGRAM's own default (:SUPERSEDE) rather than :APPEND --
        ;; see START-OLLAMA-SERVER's comment (providers/ollama.lisp)
        ;; for why :APPEND alone errors when LOG doesn't exist yet.
        (uiop:launch-program (list* (namestring apfel) "--serve" "--port" (princ-to-string (apfel-port provider))
                                     (apfel-extra-args provider))
                              :output log :error-output log))
      t)))

(defmethod provider-ensure-ready ((provider apfel-provider))
  ;; Two independent checks, in order: (1) is anything there at all --
  ;; start one if not, waiting (with a timeout) for it to come up; (2)
  ;; regardless of whether we just started it or it was already
  ;; running, is Apple Intelligence itself actually available through
  ;; it. The second check must NOT be nested inside the first (an
  ;; earlier version of this method did exactly that bug: an already-
  ;; running-but-model-unavailable server silently skipped the warning
  ;; entirely, since nothing needed starting) -- see
  ;; t/test-apfel-ensure-ready.lisp's regression test for this.
  (let ((health (apfel-health provider)))
    (unless health
      (format *error-output* "~&[apfel] server not reachable at ~a; starting `apfel --serve`...~%" (apfel-root provider))
      (unless (start-apfel-server provider)
        (error 'provider-error :provider (provider-display-name provider)
               :message (format nil "no apfel server is reachable at ~a, and no `apfel` executable was found ~
                                      on PATH to start one. Install it with `brew install apfel` (macOS 26+, ~
                                      Apple Silicon, with Apple Intelligence enabled) -- see https://apfel.franzai.com -- ~
                                      or start `apfel --serve --port ~d` yourself and try again."
                                 (apfel-root provider) (apfel-port provider))))
      (loop with deadline = (+ (get-internal-real-time) (* *apfel-start-timeout* internal-time-units-per-second))
            until (setf health (apfel-health provider))
            do (if (> (get-internal-real-time) deadline)
                   (error 'provider-error :provider (provider-display-name provider)
                          :message (format nil "started `apfel --serve` but it did not become reachable at ~a ~
                                                 within ~d seconds; see ~a for its log."
                                            (apfel-root provider) *apfel-start-timeout*
                                            (merge-pathnames "apfel-serve.log" *config-directory*)))
                   (sleep 0.5)))
      (format *error-output* "~&[apfel] server is up.~%"))
    (unless (eq (jget health "model_available") t)
      (format *error-output* "~&[apfel] server is up, but model_available is ~a -- Apple Intelligence may not ~
                               be enabled (see System Settings); requests may fail.~%"
              (jget health "model_available")))))

(register-provider-class :apple 'apfel-provider)
(register-provider-class :apfel 'apfel-provider)
