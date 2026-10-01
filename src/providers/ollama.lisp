;;;; providers/ollama.lisp -- a local Ollama server. Ollama exposes an
;;;; OpenAI-compatible /v1/chat/completions endpoint and needs no API
;;;; key at all; the one thing this provider needs beyond that shared
;;;; machinery is PROVIDER-ENSURE-READY, below: if `ollama serve` isn't
;;;; already running, start it (and wait for it to come up) rather
;;;; than fail with a connection error and make the user do that by
;;;; hand.
;;;;
;;;; This is also the provider t/test-ollama-integration.lisp exercises
;;;; end-to-end (real HTTP, real small model) via `make test-ollama`.

(in-package :cl-agent)

(defclass ollama-provider (openai-compatible-provider)
  ()
  (:default-initargs :base-url "http://localhost:11434/v1")
  (:documentation "A local Ollama server (https://ollama.com). No API
key required; CL_AGENT_OLLAMA_BASE_URL or :base-url in config can
point this at a non-default host/port."))

(defmethod provider-default-model ((provider ollama-provider)) "qwen2.5:0.5b")
(defmethod provider-display-name ((provider ollama-provider)) "Ollama")
;; Deliberately no PROVIDER-API-KEY-ENV-VAR method: the LLM-PROVIDER
;; default (NIL) is correct here, so MAKE-PROVIDER never demands a key.

(defparameter *ollama-start-timeout* 20
  "Seconds PROVIDER-ENSURE-READY will wait for a just-started `ollama
serve` to become reachable before giving up.")

(defun ollama-api-root (provider)
  "Ollama's native API (as opposed to its OpenAI-compatible /v1 one)
lives at the same host/port without the /v1 suffix; PROVIDER-BASE-URL
is .../v1 (see this file's DEFCLASS), so strip it to get .../api/tags,
.../api/pull, etc."
  (let ((base (provider-base-url provider)))
    (if (and (>= (length base) 3) (string= base "/v1" :start1 (- (length base) 3)))
        (subseq base 0 (- (length base) 3))
        base)))

(defun ollama-reachable-p (provider)
  "True if PROVIDER's Ollama server responds to a quick request."
  (handler-case
      (multiple-value-bind (body status)
          (drakma:http-request (concatenate 'string (ollama-api-root provider) "/api/tags")
                                :connection-timeout 2)
        (declare (ignore body))
        (= status 200))
    (error () nil)))

(defun find-executable-on-path (name)
  "Return the pathname of the first NAME found on $PATH, or NIL. No
portable `which` in UIOP, so this is a small manual search -- used
only to give a clear error before trying to launch `ollama serve`
rather than let that attempt fail with a confusing ENOENT."
  (loop for dir in (uiop:split-string (or (uiop:getenv "PATH") "") :separator '(#\:))
        for candidate = (ignore-errors (probe-file (merge-pathnames name (uiop:ensure-directory-pathname dir))))
        when candidate return candidate))

(defun start-ollama-server ()
  "Launch `ollama serve` as a detached background process (its own
stdout/stderr redirected to ~/.config/cl-agent/ollama-serve.log, so it
doesn't spam whatever UI frontend is active -- see ui/frontend.lisp --
but is still inspectable if something goes wrong). Deliberately not
waited on, joined, or killed when cl-agent exits: `ollama serve` is
meant to be a persistent background service, the same way starting it
by hand and leaving the terminal open would be. Returns T if launched,
NIL if no `ollama` executable is on PATH."
  (let ((ollama (find-executable-on-path "ollama")))
    (when ollama
      (ensure-config-directory)
      (let ((log (merge-pathnames "ollama-serve.log" *config-directory*)))
        ;; :IF-OUTPUT-EXISTS/:IF-ERROR-OUTPUT-EXISTS deliberately left
        ;; at LAUNCH-PROGRAM's own default, :SUPERSEDE, not :APPEND:
        ;; per CLHS, :APPEND without an explicit :IF-DOES-NOT-EXIST
        ;; defaults to erroring if LOG doesn't exist yet (which it
        ;; usually won't, the first time this runs), while :SUPERSEDE's
        ;; default is :CREATE -- so :SUPERSEDE is the one that actually
        ;; works whether or not the file is already there. A fresh log
        ;; per start attempt is the more useful behavior anyway.
        (uiop:launch-program (list (namestring ollama) "serve") :output log :error-output log))
      t)))

(defmethod provider-ensure-ready ((provider ollama-provider))
  (unless (ollama-reachable-p provider)
    (format *error-output* "~&[ollama] server not reachable at ~a; starting `ollama serve`...~%"
            (ollama-api-root provider))
    (unless (start-ollama-server)
      (error 'provider-error :provider (provider-display-name provider)
             :message (format nil "no ollama server is reachable at ~a, and no `ollama` executable ~
                                    was found on PATH to start one. Install it from https://ollama.com, ~
                                    or start `ollama serve` yourself and try again."
                               (ollama-api-root provider))))
    (loop with deadline = (+ (get-internal-real-time) (* *ollama-start-timeout* internal-time-units-per-second))
          until (ollama-reachable-p provider)
          do (if (> (get-internal-real-time) deadline)
                 (error 'provider-error :provider (provider-display-name provider)
                        :message (format nil "started `ollama serve` but it did not become reachable ~
                                               at ~a within ~d seconds; see ~a for its log."
                                          (ollama-api-root provider) *ollama-start-timeout*
                                          (merge-pathnames "ollama-serve.log" *config-directory*)))
                 (sleep 0.5)))
    (format *error-output* "~&[ollama] server is up.~%")))

(register-provider-class :ollama 'ollama-provider)
