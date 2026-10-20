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

(defun user-config-directory ()
  "The per-user default, ~/.config/cl-agent/."
  (merge-pathnames ".config/cl-agent/" (user-homedir-pathname)))

(defun default-config-directory ()
  "CL_AGENT_CONFIG_DIR when it is set (the test suite points it at a
temporary directory), else USER-CONFIG-DIRECTORY."
  (let ((env (uiop:getenv "CL_AGENT_CONFIG_DIR")))
    (if (and env (plusp (length env)))
        (uiop:ensure-absolute-pathname (uiop:parse-native-namestring env :ensure-directory t)
                                       (uiop:getcwd))
        (user-config-directory))))

(defparameter *config-directory* (default-config-directory)
  "Root of cl-agent's per-user state: config.lisp lives directly here;
extensions/ and scratch/ are subdirectories of this (see extensions.lisp).
--config-dir, then CL_AGENT_CONFIG_DIR, then ~/.config/cl-agent/ (see
DEFAULT-CONFIG-DIRECTORY).  Set it -- not just bind it -- to move every
thread's state; a LET binding is invisible to other threads.")

(defparameter *config-file-name* "config.lisp"
  "Filename, relative to *CONFIG-DIRECTORY*, of the user's config plist.")

(defparameter *user-config-grammar*
  (sexp-config:make-source-grammar
   :label "cl-agent config.lisp" :maximum-depth 32 :maximum-nodes 4096
   :maximum-string-characters 262144 :block-comments-permitted-p t)
  "Bounded inert-data grammar for the user configuration file.")

(defun config-file-path ()
  (merge-pathnames *config-file-name* *config-directory*))

(defun ensure-config-directory ()
  "Create *CONFIG-DIRECTORY* (and its extensions/ and scratch/ subdirectories) if they
don't exist yet. Safe to call repeatedly."
  (ensure-directories-exist *config-directory*)
  (ensure-directories-exist (extensions-directory))
  (ensure-directories-exist (scratch-directory))
  (values))

(defun load-user-config (&optional (path (config-file-path)))
  "Read the plist in PATH (default *CONFIG-FILE-PATH*) and return it,
or NIL if the file doesn't exist. Recognized keys, all optional:

  :PROVIDER       keyword naming a registered provider, e.g. :reallms,
                   :openai, :anthropic, :xai, :ollama, :apple (same as
                   :apfel), or the name of a provider an extension
                   registered.
  :MODEL          string, overrides the provider's default model.
  :API-KEY-ENV    string, overrides the environment variable name the
                   provider reads its API key from.
  :BASE-URL       string, overrides an OpenAI-compatible provider's
                   base URL (handy for a self-hosted/alternate endpoint).
  :SYSTEM-PROMPT  string, overrides the default system prompt.
  :ORCHESTRATION-MODE  :DIRECT (default) submits user input directly;
                   :PLAN makes an isolated planning request first;
                   :PLAN-REVIEW also verifies proposed final answers.
  :ORCHESTRATION-TOOL-LIMIT  positive integer; maximum tool schemas available
                   in :PLAN or :PLAN-REVIEW mode (default 8). Discovery cannot
                   exceed it.
  :EXTENSIONS     list of filenames (strings, relative to the
                   extensions directory) to load at startup, or the
                   keyword :ALL to load every *.lisp file found there.
                   Defaults to :ALL if the key is absent entirely --
                   see extensions.lisp.
  :MAX-TOOL-ITERATIONS  integer, caps how many tool-call round trips a
                   single turn may take before the agent gives up and
                   hands control back to the user (default 1000).
  :CONTEXT-COMPACTION-THRESHOLD  number between 0.0 and 1.0; when the
                   estimated context exceeds this fraction of a provider's
                   advertised window, compact older history before the next
                   request (default 0.8). Set 0 or 1.0 to disable automatic
                   compaction.
  :MAX-SUBAGENT-DEPTH  non-negative integer limiting delegation nesting
                   (default 1: the host may create workers, but workers may
                   not create further workers).
  :SUBAGENT-MODEL-PROFILES  list of named routing profiles for bounded
                   subagent work. Both of these inert-data forms work:
                     ((:deep-research \"glm-5.2\" :DESCRIPTION \"architecture\"
                                        :MAX-TOOL-ITERATIONS 16)
                      (:tool \"small-fast-model\" :DESCRIPTION \"quick inspection\"))
                     ((:NAME \"deep-research\" :MODEL \"glm-5.2\"
                                                 :DESCRIPTION \"architecture\"))
                   The host model sees each name, model, and description and
                   selects a profile when it delegates. No profile means the
                   worker retains the host model. A :TOOL profile is the
                   default for EXPLORE-PROJECT. Optional :SYSTEM-PROMPT adds
                   profile-specific worker guidance; optional positive
                   :MAX-TOOL-ITERATIONS overrides that worker's tool budget.
  :UI             keyword naming a registered UI frontend, e.g. :cli
                   (default), :tui, :web, or one an extension
                   registered (see ui/frontend.lisp). Overridden by
                   --ui / CL_AGENT_UI the same way :PROVIDER is.
  :MCP-SERVERS    list of (:name STRING :command (STRING...)) plists,
                   each auto-connected at startup via CONNECT-MCP-
                   SERVER (src/mcp/client.lisp); e.g. ((:name
                   \"filesystem\" :command (\"npx\" \"-y\"
                   \"@modelcontextprotocol/server-filesystem\" \"/tmp\"))).
                   A single (:name ... :command ...) plist is also accepted.
                   Optional :TIMEOUT SECONDS sets how long each of that
                   server's tool calls may take (default 30), e.g.
                   (:name \"rea\" :command (\"npx\" \"-y\"
                   \"rea-agents@6.7.0\" \"mcp\") :timeout 600).
                   A server that fails to connect is reported and
                   skipped, not fatal to startup.
  LSP servers are configured separately in config-dir/lsp.sexp using
                   cl-lsp's bounded (:VERSION 1 :SERVERS (...)) data format.
                   At startup cl-agent reports commands missing from PATH but
                   starts no LSP process until an LSP tool queries a matching
                   source file.
  Skills are discovered from .agents/skills/ in the current project (first)
                   and config-dir/skills/ (second). Both standard SKILL.md and
                   cl-skills' SKILL.sexp sources are accepted; instruction
                   bodies are read only when the agent calls READ-SKILL.

This function only ever calls READ on the file contents, never LOAD or
EVAL, and binds *READ-EVAL* to NIL while doing so -- config.lisp is
meant to be inert data, even though extensions/*.lisp (deliberately)
is not. If you want code to run at startup, write an extension."
  (when (probe-file path)
    (sexp-config:read-source-file path *user-config-grammar*
                                  :maximum-octets 1048576)))

(defun config-value (config key &optional default)
  "GETF with a DEFAULT, for readability at call sites: (config-value
cfg :model \"fallback\")."
  (getf config key default))

(defun mcp-server-specs (value)
  "Normalize :MCP-SERVERS configuration VALUE to a list of server plists.

The documented form is a list of (:NAME ... :COMMAND ...) plists.  Accept a
single such plist too: early configuration examples used that natural-looking
form, and treating its leading :NAME as a list element made every startup
fail with a bare \"malformed property list\" error."
  (cond
    ((null value) nil)
    ((and (listp value) (keywordp (first value))) (list value))
    ((listp value) value)
    (t (error ":MCP-SERVERS must be a server plist or a list of server plists, got ~s"
              value))))

(defun config-text-with-model (text model &key replace)
  "TEXT (config.lisp's contents) with :MODEL set to MODEL, edited in place so
its comments and layout survive: with REPLACE, the existing :MODEL string is
replaced; otherwise :MODEL is added first in the plist."
  (cond
    ((zerop (length (string-trim '(#\Space #\Tab #\Newline) text))) (format nil "(:model ~s)~%" model))
    (replace
     (let* ((key (search ":model" text :test #'char-equal))
            (open (and key (position #\" text :start key)))
            (close (and open (position #\" text :start (1+ open)))))
       (unless close (error "config.lisp has a :model that is not a string; edit it by hand."))
       (concatenate 'string (subseq text 0 open) (prin1-to-string model) (subseq text (1+ close)))))
    (t
     ;; The plist's own open paren: the first one outside a comment.
     (let ((open (loop with i = 0
                       while (< i (length text))
                       do (case (char text i)
                            (#\; (setf i (or (position #\Newline text :start i) (length text))))
                            (#\( (return i))
                            (t (incf i))))))
       (unless open (error "config.lisp does not hold a plist; edit it by hand."))
       (concatenate 'string (subseq text 0 (1+ open)) (format nil ":MODEL ~s~% " model)
                    (subseq text (1+ open)))))))

(defun save-config-model (model &optional (path (config-file-path)))
  "Make MODEL the default :MODEL in config.lisp (see CONFIG-TEXT-WITH-MODEL).
The edited text is read back with LOAD-USER-CONFIG before it replaces the
file, so a file it cannot edit cleanly is left alone.  Returns PATH."
  (let* ((exists (probe-file path))
         (text (if exists (uiop:read-file-string path) ""))
         (new (config-text-with-model text model
                                      :replace (and exists (getf (load-user-config path) :model) t)))
         (check (uiop:tmpize-pathname (merge-pathnames "cl-agent-config-check.lisp" (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (write-string-atomically check new)
           (unless (equal (getf (load-user-config check) :model) model)
             (error "Could not set :model in ~a safely; edit it by hand." path)))
      (ignore-errors (delete-file check)))
    (ensure-directories-exist path)
    (write-string-atomically path new)
    path))
