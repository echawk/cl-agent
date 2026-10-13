;;;; providers/provider.lisp -- the LLM-PROVIDER base class and the
;;;; generic function protocol every backend implements.
;;;;
;;;; WHY THIS FILE EXISTS (read this before adding a provider): the
;;;; task this project started from explicitly warns against
;;;; hard-wiring the agent to one LLM vendor. Every provider --
;;;; REALLMS, OpenAI, xAI/Grok, Ollama, Anthropic, and whatever you add
;;;; next -- implements the generic functions below.
;;;; repl.lisp, main.lisp, and every tool only ever call these
;;;; functions; none of them know or care which concrete class they're
;;;; talking to. That is what makes `--provider ollama` vs `--provider
;;;; anthropic` a one-line config change instead of an if/else chain
;;;; threaded through the whole codebase.
;;;;
;;;; TO ADD A NEW PROVIDER (including as a self-written extension, see
;;;; extensions.lisp): subclass LLM-PROVIDER (or OPENAI-COMPATIBLE-
;;;; PROVIDER in openai-compatible.lisp, if your backend speaks the
;;;; OpenAI chat/completions wire format -- most do), implement CHAT
;;;; (and PROVIDER-API-KEY-ENV-VAR / PROVIDER-DEFAULT-MODEL if
;;;; relevant), and call REGISTER-PROVIDER-CLASS with a keyword name.
;;;; See providers/ollama.lisp for the shortest real example.

(in-package :cl-agent)

(defclass llm-provider ()
  ((model :initarg :model :accessor provider-model :initform nil
          :documentation "Model identifier string to request. NIL
means \"use (provider-default-model this)\"; MAKE-PROVIDER resolves
this at construction time, so by the time CHAT runs, MODEL is always
a concrete string."))
  (:documentation "Abstract base class for every LLM backend. Never
instantiate this directly; instantiate a concrete subclass (usually
via MAKE-PROVIDER, not MAKE-INSTANCE, so API keys and defaults get
resolved consistently)."))

(defgeneric chat (provider messages tools)
  (:documentation
   "Send one chat-completion request to PROVIDER and return the
model's reply as a single normalized ASSISTANT-MESSAGE plist:

  (:role \"assistant\" :content STRING-OR-NIL :tool-calls TOOL-CALLS
   :usage USAGE-OR-NIL)

where TOOL-CALLS is a (possibly empty) list of

  (:id STRING :name STRING :arguments HASH-TABLE)

and USAGE, when the provider reports it, is

  (:prompt-tokens N :completion-tokens N :total-tokens N)

-- NIL when unavailable (not every provider/request reports usage; see
CHAT-STREAM's docstring for why a streamed turn commonly won't). Only
:ROLE/:CONTENT/:TOOL-CALLS are load-bearing elsewhere in this project
(repl.lisp); :USAGE is read, if present, purely to accumulate
SESSION-STATS for display (see ui/frontend.lisp's UI-STATS-UPDATED).

MESSAGES is a list of normalized message plists in the same shape
this function returns, plus:
  user:   (:role \"user\" :content STRING)
  system: (:role \"system\" :content STRING)
  tool:   (:role \"tool\" :tool-call-id STRING :content STRING)

TOOLS is a list of TOOL instances (see tools.lisp); pass NIL for a
turn where the model shouldn't be offered any tools at all.

This is the ONLY generic function every provider is required to
implement from scratch; openai-compatible.lisp's :AROUND-free default
method factors CHAT into BUILD-REQUEST-BODY + an HTTP POST +
PARSE-CHAT-RESPONSE specifically so that request/response shaping can
be unit-tested (see t/test-providers.lisp) without a network call --
new OpenAI-compatible providers should specialize those two instead of
CHAT itself. A provider with a genuinely different wire protocol
(Anthropic's Messages API is the example in this codebase) implements
CHAT directly."))

(defgeneric chat-stream (provider messages tools on-delta)
  (:documentation
   "Like CHAT, but calls (FUNCALL ON-DELTA CHUNK) with each new bit of
visible text as it arrives, before returning the same normalized
ASSISTANT-MESSAGE plist CHAT returns (built up from the accumulated
chunks) once the response is complete. This is what lets a UI frontend
(ui/frontend.lisp's UI-ASSISTANT-DELTA) show the model's reply
appearing live instead of all at once.

Default method (here, on LLM-PROVIDER): just calls CHAT once, and
calls ON-DELTA a single time with the complete :CONTENT if non-NIL --
i.e. \"no real streaming, but still correct,\" the right fallback for
a provider that hasn't implemented incremental delivery (a frontend
only sees one update instead of many; it still gets the final
message). OPENAI-COMPATIBLE-PROVIDER (providers/openai-compatible.lisp)
overrides this with real Server-Sent-Events streaming; a provider with
its own streaming wire format (Anthropic's, say) would override it
the same way CHAT itself can be overridden directly.

USAGE is commonly NIL on a real streamed response: getting per-request
token counts while streaming requires an extra request field
(`stream_options.include_usage`) that not every OpenAI-compatible
backend tolerates (some reject unrecognized fields outright -- see
providers/apfel.lisp's header comment), so this project doesn't send
it; SESSION-STATS (repl.lisp) simply accumulates whatever usage values
do show up rather than depending on every turn having one.")
  (:method ((provider llm-provider) messages tools on-delta)
    (let ((message (chat provider messages tools)))
      (when (getf message :content) (funcall on-delta (getf message :content)))
      message)))

(defgeneric provider-default-model (provider)
  (:documentation "The model string to use when the user/config didn't
specify one. Each concrete provider class should specialize this
rather than hard-coding a default model string into its CHAT method,
so MAKE-PROVIDER can report the resolved model name back to the user.")
  (:method ((provider llm-provider))
    (error "~a does not define a default model; pass :model explicitly."
           (type-of provider))))

(defgeneric provider-display-name (provider)
  (:documentation "Short human-readable name for banners/errors, e.g.
\"ollama\" or \"Anthropic\". Defaults to the class name.")
  (:method ((provider llm-provider))
    (string-downcase (class-name (class-of provider)))))

(defgeneric provider-api-key-env-var (provider)
  (:documentation "Name of the environment variable MAKE-PROVIDER
should read an API key from if none was supplied explicitly, or NIL
if this provider doesn't need one (e.g. a local Ollama server).")
  (:method ((provider llm-provider)) nil))

(defgeneric provider-ensure-ready (provider)
  (:documentation "Called once by MAKE-PROVIDER, after PROVIDER is
fully constructed (model/key resolved), before it's handed back to the
caller. Default: no-op -- most providers are just an HTTP client
against someone else's already-running server, nothing to prepare.
A provider backed by something cl-agent can itself start overrides
this to do so: OLLAMA-PROVIDER's method (providers/ollama.lisp) checks
whether a local Ollama server is reachable and, if not, launches
`ollama serve` and waits for it, so \"use ollama\" doesn't require a
separate manual step. Signal PROVIDER-ERROR if PROVIDER truly can't be
made ready (e.g. the backing executable isn't installed at all).")
  (:method ((provider llm-provider)) (values)))

(defgeneric provider-list-models (provider)
  (:documentation "Return the model identifiers currently available from
PROVIDER.  Providers that expose an OpenAI-style `GET /models` endpoint
implement this; the default says discovery is unavailable rather than
pretending that a hard-coded default is a complete list." )
  (:method ((provider llm-provider)) nil))

(defgeneric provider-for-model (provider model)
  (:documentation "Return an independent provider configured exactly like
PROVIDER except that it requests MODEL.  This lets an agent ask a second
LLM instance with a selected model without changing its main session.")
  (:method ((provider llm-provider) model)
    (declare (ignore model))
    (error "~a cannot create a second request with a selected model."
           (provider-display-name provider))))

(defgeneric provider-context-window (provider)
  (:documentation
   "Return the context-window size in tokens for PROVIDER's current model,
or NIL if unknown.  The agent loop uses this advisory capacity to compact
history before a request exceeds a known limit.")
  (:method ((provider llm-provider))
    (declare (ignore provider))
    nil))

;;; --- context windows servers advertise ---
;;;
;;; Many servers say how large each model's context is in their model
;;; listing.  Asking before every request would be slow, so a listing is
;;; cached per server; a failed or silent one is cached briefly too.

(defparameter *advertised-context-window-fields*
  '(("loaded_context_length") ("max_input_tokens") ("context_length") ("context_window")
    ("max_context_length") ("max_model_len") ("top_provider" "context_length")
    ("meta" "n_ctx_train"))
  "Where a model listing puts a model's context window, most specific first:
LM Studio (loaded_context_length, max_context_length), LiteLLM gateways
such as REALLMS (max_input_tokens), OpenRouter, Together and Fireworks
(context_length), Groq (context_window), vLLM (max_model_len), llama.cpp
(meta.n_ctx_train).")

(defparameter *context-window-cache-seconds* 600
  "How long a server's advertised windows are reused before asking again.")
(defparameter *context-window-retry-seconds* 60
  "How long to wait before asking again after a listing failed or said nothing.")

(defvar *context-window-cache* (make-hash-table :test 'equal)
  "Cache key -> (EXPIRES-AT . TABLE of model id -> window).")
(defvar *context-window-cache-lock* (bt:make-lock "cl-agent-context-windows"))

(defun positive-token-count (value)
  "VALUE as a positive integer token count, or NIL (servers send integers,
floats such as 131072.0, or numeric strings)."
  (let ((number (typecase value
                  (integer value)
                  (real (round value))
                  (string (ignore-errors (parse-integer value :junk-allowed t))))))
    (and (integerp number) (plusp number) number)))

(defun model-entry-context-window (entry)
  "The context window one model listing ENTRY (a JSON object) advertises, or NIL."
  (loop for path in *advertised-context-window-fields*
        for window = (positive-token-count (apply #'jpath entry path))
        when window return window))

(defun cached-context-windows (key fetch-entries)
  "A hash table of model id -> advertised window for the server named by
KEY, from the model listing entries FETCH-ENTRIES returns, cached for
*CONTEXT-WINDOW-CACHE-SECONDS*.  Never signals: a failure gives an empty
table, retried after *CONTEXT-WINDOW-RETRY-SECONDS*."
  (let ((now (get-universal-time)))
    (let ((cached (bt:with-lock-held (*context-window-cache-lock*) (gethash key *context-window-cache*))))
      (if (and cached (< now (car cached)))
          (cdr cached)
          (let ((table (make-hash-table :test 'equal)))
            (dolist (entry (ignore-errors (funcall fetch-entries)))
              (let ((id (or (jget entry "id") (jget entry "name")))
                    (window (model-entry-context-window entry)))
                (when (and (stringp id) window)
                  (setf (gethash id table) window))))
            (bt:with-lock-held (*context-window-cache-lock*)
              (setf (gethash key *context-window-cache*)
                    (cons (+ now (if (plusp (hash-table-count table))
                                     *context-window-cache-seconds*
                                     *context-window-retry-seconds*))
                          table)))
            table)))))

(defun forget-context-windows ()
  "Drop every cached advertised window (e.g. after a server's models change)."
  (bt:with-lock-held (*context-window-cache-lock*)
    (clrhash *context-window-cache*)))
