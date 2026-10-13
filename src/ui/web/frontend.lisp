;;;; ui/web/frontend.lisp -- WEB-FRONTEND: the AGENT-FRONTEND protocol
;;;; (ui/frontend.lisp) implemented as state plus a stream of events.
;;;;
;;;; Every UI-* call updates the frontend's state under one lock and, in
;;;; the same critical section, appends a numbered event ("message",
;;;; "delta", "activity", "status", "subagents", ...) to a bounded log.
;;;; A page loads GET /api/state (a full snapshot carrying the current
;;;; sequence number) and then follows GET /api/events?since=SEQ, a
;;;; Server-Sent Events stream of everything after it -- so nothing is
;;;; missed or duplicated between the two, and a reconnecting page either
;;;; catches up from the log or, if it fell too far behind, is told to
;;;; "resync" from a fresh snapshot.
;;;;
;;;; WEB-UI-BROADCAST publishes an arbitrary event to every open page;
;;;; the client re-emits it as CLAgent.on(TYPE, ...) for plugins, which is
;;;; how Lisp code (an extension, a slash command, the web-ui-command tool)
;;;; drives the browser: toasts, theme changes, opening a panel, reloads.
;;;;
;;;; Threading is as before: hunchentoot answers each request on its own
;;;; thread; typed input reaches the conversation thread (blocked in
;;;; UI-PROMPT-INPUT) through a trivial-channels channel.

(in-package :cl-agent)

(defparameter *web-event-log-size* 4000
  "Events kept for reconnecting pages; older ones force a resync.")

(defparameter *web-activity-limit* 3000
  "Activity entries kept in memory and in snapshots.")

(defparameter *web-activity-text-limit* 20000
  "Characters of a single activity entry (e.g. a tool's output) kept for display.")

(defclass web-frontend (queued-input-mixin)
  ((port :initarg :port :initform 4567 :accessor web-frontend-port)
   (acceptor :initform nil :accessor web-frontend-acceptor)
   (config-directory :initform *config-directory* :reader web-frontend-config-directory
                     :documentation "*CONFIG-DIRECTORY* when this frontend was made; request
threads rebind it, since hunchentoot's workers don't inherit dynamic bindings.")
   (session :initform nil :accessor web-frontend-session
            :documentation "The AGENT-SESSION this frontend serves, captured in UI-START.")
   (transcript :initform nil :accessor web-frontend-transcript
               :documentation "Entry plists (:id :role :text :html :turn :time :inline), newest first.")
   (pending :initform "" :accessor web-frontend-pending
            :documentation "Streamed text of the reply in progress.")
   (thinking :initform nil :accessor web-frontend-thinking-p)
   (planning :initform nil :accessor web-frontend-planning-p)
   (queued :initform nil :accessor web-frontend-queued)
   (activity :initform nil :accessor web-frontend-activity
             :documentation "Entry plists (:id :kind :label :text :turn :time :ref), newest first.")
   (open-tool-calls :initform nil :accessor web-frontend-open-tool-calls
                    :documentation "Alist (tool-name . activity-id) of calls awaiting output.")
   (subagents :initform nil :accessor web-frontend-subagents)
   (stats :initform nil :accessor web-frontend-stats)
   (turn :initform 0 :accessor web-frontend-turn
         :documentation "Number of user inputs so far: the N of (C N) / (D N).")
   (next-id :initform 0 :accessor web-frontend-next-id)
   (seq :initform 0 :accessor web-frontend-seq)
   (events :initform nil :accessor web-frontend-events
           :documentation "(SEQ . JSON-STRING) event log, newest first.")
   (event-count :initform 0 :accessor web-frontend-event-count)
   (stopped :initform nil :accessor web-frontend-stopped-p)
   (state-lock :initform (bt:make-lock "cl-agent-web-state") :accessor web-frontend-state-lock)
   (state-cv :initform (bt:make-condition-variable) :accessor web-frontend-state-cv)
   (input-channel :initform (trivial-channels:make-channel) :accessor web-frontend-input-channel))
  (:documentation "Browser UI at http://127.0.0.1:PORT/.  See ui/web/*.lisp."))

(defvar *web-model-choice-pending* nil
  "True while the page should ask which model to use: started with --ui web
and no configured model, so the terminal did not prompt (main.lisp).")

(defvar *web-instance-id*
  (format nil "~36r-~36r" (get-universal-time) (random (expt 36 6) (make-random-state t)))
  "Identifies this process to pages, so one that outlived a restart resyncs.")

(defun unix-time-now ()(- (get-universal-time) 2208988800))
(defun universal-to-unix-time (universal) (and universal (- universal 2208988800)))

(defun web-frontend-notify (frontend)
  "Wake every page waiting for events.  Caller holds the state lock."
  #+sbcl (sb-thread:condition-broadcast (web-frontend-state-cv frontend))
  #-sbcl (bt:condition-notify (web-frontend-state-cv frontend)))

(defun web-frontend-publish (frontend type payload)
  "Append event TYPE with PAYLOAD (a JOBJ) to the log.  Caller holds the lock."
  (let ((seq (incf (web-frontend-seq frontend))))
    (setf (gethash "type" payload) type
          (gethash "seq" payload) seq)
    (push (cons seq (json-encode payload)) (web-frontend-events frontend))
    (when (> (incf (web-frontend-event-count frontend)) (* 2 *web-event-log-size*))
      (setf (web-frontend-events frontend)
            (subseq (web-frontend-events frontend) 0 *web-event-log-size*)
            (web-frontend-event-count frontend) *web-event-log-size*))
    (web-frontend-notify frontend)
    seq))

(defmacro with-web-state ((frontend) &body body)
  `(bt:with-lock-held ((web-frontend-state-lock ,frontend)) ,@body))

(defun web-ui-broadcast (type payload)
  "Publish event TYPE (a string) with PAYLOAD (a JOBJ, copied per page) to
every open web page, where CLAgent.on(TYPE, handler) receives it."
  (dolist (frontend *web-frontends*)
    (let ((copy (jobj)))
      (when (hash-table-p payload)
        (maphash (lambda (key value) (setf (gethash key copy) value)) payload))
      (with-web-state (frontend) (web-frontend-publish frontend type copy))))
  (length *web-frontends*))

(defun web-ui-command (command &optional (args (jobj)))
  "Ask every open page to run client COMMAND (\"toast\", \"theme\",
\"panel\", \"reload\", \"insert\", or one a plugin registered with
CLAgent.registerUICommand) with ARGS, a JOBJ."
  (web-ui-broadcast "ui" (jobj "command" command "args" args)))

;;; --- State changes (each publishes its event) ---

(defun web-entry-json (entry)
  (jobj "id" (getf entry :id) "role" (getf entry :role) "text" (getf entry :text)
        "html" (json-or-null (getf entry :html)) "turn" (getf entry :turn)
        "time" (getf entry :time) "inline" (and (getf entry :inline) t)))

(defun web-activity-json (entry)
  (jobj "id" (getf entry :id) "kind" (getf entry :kind) "label" (getf entry :label)
        "text" (getf entry :text) "turn" (getf entry :turn) "time" (getf entry :time)
        "ref" (json-or-null (getf entry :ref)) "tool" (json-or-null (getf entry :tool))))

(defun web-frontend-push (frontend role text &key html inline)
  "Append a transcript entry and publish it as a \"message\" event."
  (with-web-state (frontend)
    (when (string= role "user") (incf (web-frontend-turn frontend)))
    (let ((entry (list :id (incf (web-frontend-next-id frontend)) :role role :text text
                       :html html :turn (web-frontend-turn frontend) :time (unix-time-now)
                       :inline inline)))
      (push entry (web-frontend-transcript frontend))
      (web-frontend-publish frontend "message" (jobj "message" (web-entry-json entry)))
      entry)))

(defun truncate-for-display (text limit)
  (if (> (length text) limit)
      (format nil "~a~%… [~d more characters not shown]" (subseq text 0 limit) (- (length text) limit))
      text))

(defun web-frontend-push-activity (frontend kind label text &key tool ref)
  "Append one labelled activity entry and publish it as an \"activity\" event."
  (with-web-state (frontend)
    (let ((entry (list :id (incf (web-frontend-next-id frontend)) :kind kind :label label
                       :text (truncate-for-display (or text "") *web-activity-text-limit*)
                       :turn (web-frontend-turn frontend) :time (unix-time-now)
                       :tool tool :ref ref)))
      (push entry (web-frontend-activity frontend))
      (when (> (length (web-frontend-activity frontend)) (+ *web-activity-limit* 200))
        (setf (web-frontend-activity frontend)
              (subseq (web-frontend-activity frontend) 0 *web-activity-limit*)))
      (web-frontend-publish frontend "activity" (jobj "entry" (web-activity-json entry)))
      entry)))

(defun web-stats-json (stats)
  (if stats
      (jobj "provider" (getf stats :provider) "model" (getf stats :model)
            "requests" (getf stats :requests 0) "tool_calls" (getf stats :tool-calls 0)
            "elapsed_seconds" (getf stats :elapsed-seconds 0)
            "prompt_tokens" (getf stats :prompt-tokens 0)
            "completion_tokens" (getf stats :completion-tokens 0)
            "total_tokens" (getf stats :total-tokens 0))
      :null))

(defun web-status-json (frontend)
  "The \"status\" fields: busy flags, queue and stats.  Caller holds the lock."
  (jobj "thinking" (web-frontend-thinking-p frontend)
        "planning" (web-frontend-planning-p frontend)
        "queued" (jarray (copy-list (web-frontend-queued frontend)))
        "turn" (web-frontend-turn frontend)
        "stats" (web-stats-json (web-frontend-stats frontend))))

(defun web-frontend-publish-status (frontend)
  "Publish the current status.  Caller holds the lock."
  (web-frontend-publish frontend "status" (jobj "status" (web-status-json frontend))))

(defun web-subagent-json (snapshot)
  "JSON view of one subagent snapshot; times are Unix seconds for the page's clock."
  (jobj "id" (getf snapshot :id)
        "state" (string-downcase (symbol-name (getf snapshot :state)))
        "role" (json-or-null (getf snapshot :role))
        "profile" (json-or-null (and (getf snapshot :profile) (princ-to-string (getf snapshot :profile))))
        "model" (json-or-null (getf snapshot :model))
        "description" (json-or-null (getf snapshot :description))
        "activity" (json-or-null (getf snapshot :activity))
        "note" (json-or-null (getf snapshot :note))
        "depth" (or (getf snapshot :depth) 1)
        "parent" (json-or-null (getf snapshot :parent))
        "tools" (jarray (mapcar #'princ-to-string (getf snapshot :tools)))
        "requests" (or (getf snapshot :requests) 0)
        "tool_calls" (or (getf snapshot :tool-calls) 0)
        "tokens" (or (getf snapshot :tokens) 0)
        "created" (json-or-null (universal-to-unix-time (getf snapshot :created-at)))
        "started" (json-or-null (universal-to-unix-time (getf snapshot :started-at)))
        "finished" (json-or-null (universal-to-unix-time (getf snapshot :finished-at)))))

(defun web-session-json (frontend)
  (let ((session (web-frontend-session frontend)))
    (jobj "id" (json-or-null (and session (ignore-errors (princ-to-string (session-id session)))))
          "name" (json-or-null (and session (ignore-errors (session-display-name session))))
          "mode" (json-or-null (and session (ignore-errors (string-downcase (session-orchestration-mode session)))))
          "capabilities" (json-or-null (and session (ignore-errors (string-downcase (session-capability-mode session)))))
          "provider" (json-or-null (and session (ignore-errors (provider-display-name (session-provider session)))))
          "model" (json-or-null (and session (ignore-errors (provider-model (session-provider session)))))
          "user" (or (uiop:getenv "USER") (uiop:getenv "USERNAME") "user")
          "host" (or (ignore-errors (machine-instance)) "localhost")
          "cwd" (namestring (uiop:getcwd))
          "home" (uiop:native-namestring (user-homedir-pathname))
          "lisp" (format nil "~a ~a" (lisp-implementation-type) (lisp-implementation-version))
          "port" (web-frontend-port frontend))))

(defun web-frontend-status-json (frontend &key safe)
  "The full snapshot GET /api/state serves (also at /api/messages, its older
name): transcript, activity, subagents, status and the SEQ of the newest
event it reflects.  Passed through the :WEB-UI-STATE chain hook."
  (let ((state
          (with-web-state (frontend)
            (let ((status (web-status-json frontend)))
              (jobj "seq" (web-frontend-seq frontend)
                    "instance" *web-instance-id*
                    "messages" (jarray (mapcar #'web-entry-json (reverse (web-frontend-transcript frontend))))
                    "pending" (web-frontend-pending frontend)
                    "thinking" (gethash "thinking" status)
                    "planning" (gethash "planning" status)
                    "queued" (gethash "queued" status)
                    "turn" (gethash "turn" status)
                    "stats" (gethash "stats" status)
                    "activity" (jarray (mapcar #'web-activity-json (reverse (web-frontend-activity frontend))))
                    "subagents" (jarray (mapcar #'web-subagent-json (web-frontend-subagents frontend))))))))
    (setf (gethash "session" state) (web-session-json frontend)
          (gethash "ui" state) (jobj "safe" (and safe t)
                                     "model_pending" (and *web-model-choice-pending* t)
                                     "patches" (jarray (web-ui-patch-paths :safe safe))
                                     "overrides" (jarray (web-asset-override-paths))
                                     "directory" (namestring (web-ui-directory))
                                     "now" (unix-time-now)))
    (json-encode (run-hook-chain :web-ui-state state))))

;;; --- Server-Sent Events ---

(defun web-frontend-events-after (frontend cursor)
  "Events newer than CURSOR, oldest first, or :RESYNC if some were dropped.
Caller holds the lock."
  (let ((events (loop for entry in (web-frontend-events frontend)
                      while (> (car entry) cursor) collect entry)))
    (if (and events (> (car (car (last events))) (1+ cursor)))
        :resync
        (nreverse events))))

(defun web-frontend-wait-events (frontend cursor timeout)
  "Block up to TIMEOUT seconds for events after CURSOR.  Returns the events
(or :RESYNC, or :STOPPED), and the new cursor."
  (with-web-state (frontend)
    (loop
      (when (web-frontend-stopped-p frontend) (return (values :stopped cursor)))
      (when (> (web-frontend-seq frontend) cursor)
        (return (values (web-frontend-events-after frontend cursor) (web-frontend-seq frontend))))
      (unless (bt:condition-wait (web-frontend-state-cv frontend) (web-frontend-state-lock frontend)
                                 :timeout timeout)
        (return (values nil cursor))))))

(defun write-sse (stream data &key event id)
  (when event (format stream "event: ~a~%" event))
  (when id (format stream "id: ~d~%" id))
  (format stream "data: ~a~%~%" data))

(defun web-frontend-serve-events (frontend since)
  "Stream events after SINCE to the current request until the page goes away
or the frontend stops.  Holds one hunchentoot worker thread per open page."
  (setf (hunchentoot:content-type*) "text/event-stream; charset=utf-8"
        (hunchentoot:header-out "X-Accel-Buffering") "no")
  (let ((out (flex:make-flexi-stream (hunchentoot:send-headers) :external-format :utf-8))
        (cursor since))
    (handler-case
        (progn
          (write-sse out (json-encode (jobj "seq" (with-web-state (frontend) (web-frontend-seq frontend))
                                            "instance" *web-instance-id*))
                     :event "hello")
          (finish-output out)
          (loop
            (multiple-value-bind (events next) (web-frontend-wait-events frontend cursor 15)
              (case events
                (:stopped (write-sse out "{}" :event "bye") (finish-output out) (return))
                (:resync (write-sse out (json-encode (jobj "seq" next)) :event "resync"))
                ((nil) (write-string (format nil ": keepalive~%~%") out))
                (t (dolist (event events) (write-sse out (cdr event) :id (car event)))))
              (setf cursor next)
              (finish-output out))))
      (error () nil))
    ""))

;;; --- The page itself ---

(defun web-patch-tags (base safe)
  (flet ((tags (extension template)
           (format nil "~{~a~^~%~}"
                   (loop for path in (web-ui-patch-paths :safe safe)
                         when (string= (web-asset-extension path) extension)
                           collect (format nil template path base path)))))
    (values (tags "css" "<link rel=\"stylesheet\" data-patch=\"~a\" href=\"~a/~a\">")
            (tags "js" "<script type=\"module\" data-patch=\"~a\" src=\"~a/~a\"></script>"))))

(defun web-index-html (&key safe)
  "index.html with its {{...}} placeholders filled, through :WEB-UI-PAGE."
  (let* ((base (if safe "/safe/assets" "/assets"))
         (html (or (find-web-asset "index.html" :safe safe)
                   (builtin-web-asset-content "index.html")
                   "<!doctype html><title>cl-agent</title><p>index.html is missing.</p>")))
    (multiple-value-bind (styles scripts) (web-patch-tags base safe)
      (dolist (pair (list (cons "{{ASSETS}}" base)
                          (cons "{{PATCH_STYLES}}" styles)
                          (cons "{{PATCH_SCRIPTS}}" scripts)
                          (cons "{{BOOT}}" (json-encode (jobj "safe" (and safe t) "assets" base)))))
        (setf html (replace-all-substrings html (car pair) (cdr pair)))))
    (getf (run-hook-chain :web-ui-page (list :html html :safe safe)) :html)))

;;; --- Lifecycle ---

(defmethod ui-start ((frontend web-frontend))
  (setf (web-frontend-session frontend) (and (boundp '*current-session*) *current-session*)
        (web-frontend-acceptor frontend) (start-web-acceptor frontend)
        *web-frontend* frontend)
  (push frontend *web-frontends*)
  (ensure-web-asset-watcher)
  (format t "~&cl-agent web UI: http://127.0.0.1:~d/   (safe mode: /safe)~%" (web-frontend-port frontend)))

(defmethod ui-stop ((frontend web-frontend))
  (with-web-state (frontend)
    (setf (web-frontend-stopped-p frontend) t)
    (web-frontend-notify frontend))
  (setf *web-frontends* (remove frontend *web-frontends*))
  (ignore-errors (hunchentoot:stop (web-frontend-acceptor frontend)))
  (when (eq *web-frontend* frontend) (setf *web-frontend* (first *web-frontends*))))

(defun web-frontend-submit (frontend text)
  "Route a line typed into the page; returns the FRONTEND-ACCEPT-INPUT status."
  (multiple-value-bind (status payload) (frontend-accept-input frontend text)
    (when (eq status :immediate)
      ;; Busy until the REPL prompts again, so a line typed while this one
      ;; (even a slash command) is still running queues behind it.
      (setf (frontend-busy-p frontend) t)
      (web-frontend-push frontend "user" payload)
      (trivial-channels:sendmsg (web-frontend-input-channel frontend) payload))
    status))

;;; --- The AGENT-FRONTEND protocol ---

(defmethod ui-prompt-input ((frontend web-frontend))
  ;; The REPL is waiting for us: nothing is running, so nothing to interrupt.
  (setf (frontend-busy-p frontend) nil
        (frontend-interrupt-flag frontend) nil)
  (trivial-channels:recvmsg (web-frontend-input-channel frontend)))

(defmethod ui-assistant-text ((frontend web-frontend) text)
  (let ((html (web-markdown-html text)))
    (with-web-state (frontend)
      (setf (web-frontend-pending frontend) "")
      (web-frontend-publish frontend "pending" (jobj "text" "")))
    (web-frontend-push frontend "assistant" text :html html)))

(defmethod ui-show-tool-call-assistant-text-p ((frontend web-frontend))
  (declare (ignore frontend))
  nil)

(defun web-message-text (content)
  (cond ((stringp content) content)
        ((null content) "")
        (t (princ-to-string content))))

(defmethod ui-tools-changed :after ((frontend web-frontend) session added removed)
  "Let the page's Tools panel refetch."
  (declare (ignore session))
  (with-web-state (frontend)
    (web-frontend-publish frontend "tools" (jobj "added" (jarray added) "removed" (jarray removed)))))

(defmethod ui-conversation-replaced ((frontend web-frontend) session)
  "Rebuild the transcript from SESSION's restored messages.  Pages reload
their state on the \"reset\" event; the conversation then arrives through
the same methods a live turn uses, so it renders the same way."
  (with-web-state (frontend)
    (setf (web-frontend-transcript frontend) nil
          (web-frontend-activity frontend) nil
          (web-frontend-open-tool-calls frontend) nil
          (web-frontend-pending frontend) ""
          (web-frontend-turn frontend) 0)
    (web-frontend-publish frontend "reset" (jobj)))
  (let ((tool-names (make-hash-table :test 'equal)))
    (dolist (message (session-messages session))
      (let ((role (getf message :role))
            (text (web-message-text (getf message :content))))
        (cond ((equal role "user") (web-frontend-push frontend "user" text))
              ((equal role "assistant")
               (when (plusp (length (string-trim '(#\Space #\Tab #\Newline) text)))
                 (ui-assistant-text frontend text))
               (dolist (call (getf message :tool-calls))
                 (setf (gethash (getf call :id) tool-names) (getf call :name))
                 (ui-tool-started frontend (or (getf call :name) "tool")
                                  (let ((arguments (getf call :arguments)))
                                    (if (hash-table-p arguments) arguments (jobj))))))
              ((equal role "tool")
               (ui-tool-finished frontend (or (gethash (getf message :tool-call-id) tool-names) "tool")
                                 nil text)))))))

(defmethod ui-discard-assistant-pending ((frontend web-frontend))
  (with-web-state (frontend)
    (setf (web-frontend-pending frontend) "")
    (web-frontend-publish frontend "pending" (jobj "text" ""))))

(defmethod ui-assistant-delta ((frontend web-frontend) chunk)
  (with-web-state (frontend)
    (setf (web-frontend-pending frontend) (concatenate 'string (web-frontend-pending frontend) chunk))
    (web-frontend-publish frontend "delta" (jobj "chunk" chunk))))

(defmethod ui-agent-activity ((frontend web-frontend) label text)
  (web-frontend-push-activity frontend "narration" label text))

(defmethod ui-session-event ((frontend web-frontend) event)
  (web-frontend-push-activity
   frontend "event"
   (format nil "EVENT · ~(~a~)" (getf event :kind))
   (format nil "#~d · ~a" (getf event :sequence) (or (getf event :status) "committed"))))

(defmethod ui-tool-started ((frontend web-frontend) tool-name arguments)
  (let ((summary (tool-call-summary tool-name arguments)))
    ;; The transcript copy keeps /api/state's "messages" a complete record
    ;; for API consumers; the page shows tools from the activity entries.
    (web-frontend-push frontend "tool" (format nil "~~ ~a" summary))
    (let ((entry (web-frontend-push-activity frontend "tool-call" (format nil "TOOL · ~a" tool-name)
                                             summary :tool tool-name)))
      (with-web-state (frontend)
        (push (cons tool-name (getf entry :id)) (web-frontend-open-tool-calls frontend))))))

(defmethod ui-tool-finished ((frontend web-frontend) tool-name arguments result)
  (declare (ignore arguments))
  (let ((ref (with-web-state (frontend)
               (let ((open (assoc tool-name (web-frontend-open-tool-calls frontend) :test #'equal)))
                 (setf (web-frontend-open-tool-calls frontend)
                       (remove open (web-frontend-open-tool-calls frontend) :count 1))
                 (cdr open)))))
    (web-frontend-push frontend "tool" result)
    (web-frontend-push-activity frontend "tool-output" (format nil "OUTPUT · ~a" tool-name)
                                result :tool tool-name :ref ref)))

(defmethod ui-system ((frontend web-frontend) text)
  ;; Output while the agent is idle answers something the user just did
  ;; (usually a slash command), so the page shows it inline in the
  ;; listener; output during a turn is progress and stays in Activity.
  (web-frontend-push frontend "system" text
                     :inline (not (or (web-frontend-thinking-p frontend) (web-frontend-planning-p frontend))))
  (web-frontend-push-activity frontend "system" "STATUS" text))

(defmethod ui-error ((frontend web-frontend) condition)
  (let ((text (format nil "~a" condition)))
    (web-frontend-push frontend "error" text :inline t)
    (web-frontend-push-activity frontend "error" "ERROR" text)))

(defmethod ui-context-compacted ((frontend web-frontend) summary before-tokens after-tokens)
  "Keep the continuity note available behind a disclosure, not inline."
  (web-frontend-push frontend "compaction" summary)
  (web-frontend-push-activity frontend "system" "CONTEXT"
                              (format nil "Context compacted: ~d -> ~d estimated tokens."
                                      before-tokens after-tokens)))

(defun web-frontend-set-busy (frontend &key (thinking nil thinking-p) (planning nil planning-p))
  (with-web-state (frontend)
    (when thinking-p (setf (web-frontend-thinking-p frontend) thinking))
    (when planning-p (setf (web-frontend-planning-p frontend) planning))
    (web-frontend-publish-status frontend)))

(defmethod ui-thinking-started ((frontend web-frontend))
  (web-frontend-set-busy frontend :thinking t))

(defmethod ui-thinking-stopped ((frontend web-frontend))
  (web-frontend-set-busy frontend :thinking nil :planning nil))

(defmethod ui-planning-started ((frontend web-frontend))
  (web-frontend-set-busy frontend :planning t)
  (web-frontend-push-activity frontend "planning" "PLAN" "Planning the next steps…"))

(defmethod ui-planning-stopped ((frontend web-frontend))
  (web-frontend-set-busy frontend :planning nil))

(defmethod ui-stats-updated ((frontend web-frontend) stats)
  (with-web-state (frontend)
    (setf (web-frontend-stats frontend) stats)
    (web-frontend-publish-status frontend)))

(defmethod ui-queue-updated ((frontend web-frontend) queued)
  (with-web-state (frontend)
    (setf (web-frontend-queued frontend) queued)
    (web-frontend-publish-status frontend)))

(defmethod ui-input-delivered ((frontend web-frontend) text)
  ;; The REPL runs a queued line without prompting first; it is busy again.
  (setf (frontend-busy-p frontend) t)
  (web-frontend-push frontend "user" text))

(defun web-frontend-refresh-subagents (frontend)
  "Re-read every subagent this frontend started -- finished ones included, for
the Agents overview's timeline -- and publish them.  Computed before taking
the state lock: the task table has its own lock, and the task code calls
into frontends while holding it."
  (let ((items (subagent-panel-snapshots frontend :linger most-positive-fixnum)))
    (with-web-state (frontend)
      (setf (web-frontend-subagents frontend) items)
      (web-frontend-publish frontend "subagents"
                            (jobj "items" (jarray (mapcar #'web-subagent-json items)))))))

(defmethod ui-subagents-updated ((frontend web-frontend) snapshots)
  (declare (ignore snapshots))
  (web-frontend-refresh-subagents frontend))

(defmethod ui-subagent-event ((frontend web-frontend) snapshot)
  (web-frontend-push-activity frontend "subagent"
                              (format nil "AGENT · ~a" (getf snapshot :id))
                              (format-subagent-event snapshot))
  (web-frontend-refresh-subagents frontend))

(register-frontend-class :web 'web-frontend)
