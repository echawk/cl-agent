;;;; providers/registry.lisp -- maps a short keyword name (:ollama,
;;;; :reallms, ...) to a provider class, and knows how to build one
;;;; with its API key and model resolved.
;;;;
;;;; Every concrete provider file (reallms.lisp, openai.lisp, ...)
;;;; ends with a call to REGISTER-PROVIDER-CLASS; an extension that
;;;; defines a brand new provider class does the same thing to make it
;;;; selectable via :provider in config.lisp or --provider on the CLI.

(in-package :cl-agent)

(defvar *provider-registry* (make-hash-table :test 'eq)
  "keyword -> class-name (a symbol), e.g. :ollama -> 'ollama-provider.")

(defun register-provider-class (keyword class-name)
  "Make KEYWORD (e.g. :ollama) a valid :PROVIDER value, backed by
CLASS-NAME (a symbol naming an LLM-PROVIDER subclass)."
  (setf (gethash keyword *provider-registry*) class-name)
  keyword)

(defun list-providers ()
  "Return an alist of (keyword . class-name) for every registered
provider, for /providers in the REPL and for error messages."
  (loop for k being the hash-keys of *provider-registry* using (hash-value v)
        collect (cons k v)))

(defun env (name)
  "UIOP:GETENV wrapper kept here so provider code has one obvious
place to look; returns NIL (not \"\") for an unset variable."
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun forget-env (name)
  "Best-effort removal of NAME from this process's environment, after
we've read an API key out of it, so tools that shell out (see
tools/shell.lisp) don't inherit it. SBCL has no portable unsetenv in
uiop across all versions, so this is SBCL-specific and silently a
no-op elsewhere; treat it as defense in depth, not a guarantee -- the
key is still resident in this Lisp image's memory for the session."
  #+sbcl
  (ignore-errors
   (progn (require :sb-posix) (funcall (find-symbol "UNSETENV" :sb-posix) name)))
  (values))

(defun make-provider (keyword &key model api-key api-key-env base-url ensure-ready)
  "Instantiate the provider registered under KEYWORD. MODEL and
API-KEY override the config/environment-derived defaults if supplied.
BASE-URL is only meaningful for OPENAI-COMPATIBLE-PROVIDER subclasses
(see openai-compatible.lisp); it is ignored (with a warning) for
others.

API key resolution order, when API-KEY is not supplied explicitly:
  1. API-KEY-ENV, if supplied, names the environment variable to read
     instead of the provider class's own default (handy for e.g.
     juggling more than one REALLMS key).
  2. Otherwise (PROVIDER-API-KEY-ENV-VAR instance-of-the-class).
  3. Either way, the variable is read via ENV then removed from the
     environment via FORGET-ENV.
  4. If the provider needs a key (the env var name from step 1 or 2 is
     non-NIL) and none was found, signal MISSING-API-KEY.

If ENSURE-READY is true, PROVIDER-ENSURE-READY is called on the new
instance before it's returned -- for OLLAMA-PROVIDER, this is what
starts `ollama serve` if it isn't already running (see
providers/ollama.lisp). Defaults to NIL (skipped) so that constructing
a provider for introspection or offline testing (see t/test-
providers.lisp, which builds dozens of these) never has a side effect
or a network dependency; main.lisp passes ENSURE-READY T when building
the provider an actual session will use.

Signals PROVIDER-NOT-FOUND for an unregistered KEYWORD."
  (let ((class-name (or (gethash keyword *provider-registry*)
                         (error 'provider-not-found :name keyword))))
    (let* ((instance (make-instance class-name))
           (env-var (or api-key-env (provider-api-key-env-var instance)))
           (resolved-key (or api-key (and env-var (env env-var)))))
      (when (and env-var (not resolved-key))
        (error 'missing-api-key :provider (provider-display-name instance) :env-var env-var))
      (when env-var (forget-env env-var))
      (when (and base-url (typep instance 'openai-compatible-provider))
        (setf (provider-base-url instance) base-url))
      (when (and base-url (not (typep instance 'openai-compatible-provider)))
        (warn "~a does not use :base-url; ignoring it." (provider-display-name instance)))
      (when (slot-exists-p instance 'api-key)
        (setf (slot-value instance 'api-key) resolved-key))
      (setf (provider-model instance) (or model (provider-default-model instance)))
      (when ensure-ready (provider-ensure-ready instance))
      instance)))
