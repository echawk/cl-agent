;;;; config.lisp -- ~/.config/cl-agent/ layout and the (data-only) user
;;;; config file.
;;;;
;;;; cl-agent keeps two very different kinds of thing under
;;;; ~/.config/cl-agent/, and it is important to keep them conceptually
;;;; separate:
;;;;
;;;;   config.lisp       DATA. A plist, read with READ (not LOADed, and
;;;;                     read with *READ-EVAL* bound to NIL so a
;;;;                     config file can't smuggle in #.(...) code
;;;;                     execution). Says which provider/model to use,
;;;;                     which extensions are enabled, etc.
;;;;
;;;;   extensions/*.lisp CODE. Ordinary Lisp source, LOADed into the
;;;;                     running image. This is the self-modification
;;;;                     surface -- see extensions.lisp.
;;;;
;;;; This file only deals with the first kind.

(in-package :cl-agent)

(defparameter *config-directory*
  (merge-pathnames ".config/cl-agent/" (user-homedir-pathname))
  "Root of cl-agent's per-user state: config.lisp lives directly here;
extensions/ is a subdirectory of this (see *EXTENSIONS-DIRECTORY* in
extensions.lisp). Rebind this (e.g. in tests, or via --config-dir) to
point somewhere else entirely.")

(defparameter *config-file-name* "config.lisp"
  "Filename, relative to *CONFIG-DIRECTORY*, of the user's config plist.")

(defun config-file-path ()
  (merge-pathnames *config-file-name* *config-directory*))

(defun ensure-config-directory ()
  "Create *CONFIG-DIRECTORY* (and its extensions/ subdirectory) if they
don't exist yet. Safe to call repeatedly."
  (ensure-directories-exist *config-directory*)
  (ensure-directories-exist (extensions-directory))
  (values))

(defun load-user-config (&optional (path (config-file-path)))
  "Read the plist in PATH (default *CONFIG-FILE-PATH*) and return it,
or NIL if the file doesn't exist. Recognized keys, all optional:

  :PROVIDER       keyword naming a registered provider, e.g. :reallms,
                   :openai, :anthropic, :xai, :ollama, :apple, or the
                   name of a provider an extension registered.
  :MODEL          string, overrides the provider's default model.
  :API-KEY-ENV    string, overrides the environment variable name the
                   provider reads its API key from.
  :BASE-URL       string, overrides an OpenAI-compatible provider's
                   base URL (handy for a self-hosted/alternate endpoint).
  :SYSTEM-PROMPT  string, overrides the default system prompt.
  :EXTENSIONS     list of filenames (strings, relative to the
                   extensions directory) to load at startup, or the
                   keyword :ALL to load every *.lisp file found there.
                   Defaults to :ALL if the key is absent entirely --
                   see extensions.lisp.
  :MAX-TOOL-ITERATIONS  integer, caps how many tool-call round trips a
                   single turn may take before the agent gives up and
                   hands control back to the user (default 25).
  :UI             keyword naming a registered UI frontend, e.g. :cli
                   (default), :tui, :web, or one an extension
                   registered (see ui/frontend.lisp). Overridden by
                   --ui / CL_AGENT_UI the same way :PROVIDER is.
  :MCP-SERVERS    list of (:name STRING :command (STRING...)) plists,
                   each auto-connected at startup via CONNECT-MCP-
                   SERVER (src/mcp/client.lisp); e.g. (:name
                   \"filesystem\" :command (\"npx\" \"-y\"
                   \"@modelcontextprotocol/server-filesystem\" \"/tmp\")).
                   A server that fails to connect is reported and
                   skipped, not fatal to startup.

This function only ever calls READ on the file contents, never LOAD or
EVAL, and binds *READ-EVAL* to NIL while doing so -- config.lisp is
meant to be inert data, even though extensions/*.lisp (deliberately)
is not. If you want code to run at startup, write an extension."
  (when (probe-file path)
    (with-open-file (in path :direction :input)
      (let ((*read-eval* nil)
            (*package* (find-package :cl-agent)))
        (read in nil nil)))))

(defun config-value (config key &optional default)
  "GETF with a DEFAULT, for readability at call sites: (config-value
cfg :model \"fallback\")."
  (getf config key default))
