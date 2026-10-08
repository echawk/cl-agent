;;;; tasks.lisp -- concurrent, process-isolated subagent tasks.
;;;;
;;;; A subagent TASK is a durable-in-memory record that owns one child SBCL
;;;; (see workers.lisp) running a real provider.  The shape is:
;;;;
;;;;   parent --(inert CONTRACT plist)--> Jobpond job --> child SBCL
;;;;                                                      builds provider +
;;;;                                                      session + tools,
;;;;                                                      runs one agent turn
;;;;   parent <--(inert RESULT plist)-----------------------/
;;;;
;;;; Every seam is open to extension, in the same style as the rest of the
;;;; agent:
;;;;
;;;;   * hooks (see *HOOK-POINTS*): :before-subagent-start rewrites the
;;;;     contract, :after-subagent-result rewrites the outcome, and
;;;;     :subagent-task-transition observes every state change;
;;;;   * roles (REGISTER-SUBAGENT-ROLE): data-only presets of prompt, tools,
;;;;     budget and child setup forms, published as components;
;;;;   * *SUBAGENT-GRANTABLE-TOOLS*: the tool allowlist a parent may grant;
;;;;   * PROVIDER-WORKER-SPEC: a generic function deciding how a provider is
;;;;     rebuilt in a child (NIL means "run in-process instead");
;;;;   * tasks are components and emit events, so they are inspectable with
;;;;     /components and event subscribers.
;;;;
;;;; The contract is plain readable data.  The child never receives parent
;;;; objects, the parent session, or dynamic bindings.

(in-package :cl-agent)

(defvar *current-session*)

;;; ------------------------------------------------------------------
;;; Configuration

(defvar *subagent-execution-mode* :worker
  "How RUN-SUBAGENT executes: :WORKER uses a child SBCL when the provider can be
rebuilt there, :IN-PROCESS always uses the legacy synchronous path.")

(defvar *subagent-max-concurrency* 3
  "Maximum child SBCL processes running at once; read when the pool is created.")
(defvar *subagent-default-max-seconds* 600
  "Wall-clock cap for a task unless its contract says otherwise.")

(defvar *subagent-grantable-tools*
  '("shell" "sandbox-shell" "read-file" "read-file-range" "lisp-apropos"
    "review-lisp" "check-parens" "lookup-cl-spec" "ask-llm")
  "Tools a parent may grant to a child.  Deliberately read-oriented: write
tools and task tools are absent.  An extension may push more names.")

(defvar *subagent-default-tools*
  '("shell" "read-file" "read-file-range" "lisp-apropos" "review-lisp" "check-parens")
  "Tools given to a child when neither the caller nor the role chooses.")

;;; ------------------------------------------------------------------
;;; Provider reconstruction

(defun provider-registry-keyword (provider)
  "Return the registry keyword whose class is exactly PROVIDER's class, or NIL."
  (loop for keyword being the hash-keys of *provider-registry* using (hash-value class)
        when (eq class (type-of provider)) return keyword))

(defgeneric provider-worker-spec (provider model)
  (:documentation "Return an inert plist (:KEYWORD :MODEL :BASE-URL :API-KEY) from
which a child process can rebuild PROVIDER with MODEL, or NIL when the provider
cannot be recreated there (unregistered class, test doubles).  Specialize this
for a provider whose reconstruction needs more than the registry offers.")
  (:method ((provider llm-provider) model)
    (let ((keyword (provider-registry-keyword provider)))
      (flet ((slot (name)
               (and (slot-exists-p provider name) (slot-boundp provider name)
                    (slot-value provider name))))
        (when keyword
          (list :keyword keyword
                :model (or model (provider-model provider))
                :base-url (slot 'base-url)
                :api-key (slot 'api-key)))))))

;;; ------------------------------------------------------------------
;;; Roles

(defvar *subagent-roles* (make-hash-table :test 'equal)
  "Role name -> plist (:NAME :DESCRIPTION :SYSTEM-PROMPT :TOOLS :PROFILE
:MAX-TOOL-ITERATIONS :MAX-SECONDS :SETUP-FORMS).  Inert data only.")

(defun register-subagent-role (name &key description system-prompt tools profile
                                      max-tool-iterations max-seconds setup-forms)
  "Define or replace the subagent role NAME and publish it as a component.
SETUP-FORMS are source strings evaluated in the child before its provider is
built; use them to load role-specific code there."
  (let* ((name (string-downcase (string name)))
         (role (list :name name :description description :system-prompt system-prompt
                     :tools tools :profile profile :max-tool-iterations max-tool-iterations
                     :max-seconds max-seconds :setup-forms setup-forms)))
    (setf (gethash name *subagent-roles*) role)
    (publish-component :subagent-role name
                       :effects (list :process)
                       :metadata (list :description description :tools tools))
    role))

(defun find-subagent-role (name)
  (and name (gethash (string-downcase (string name)) *subagent-roles*)))

(defun list-subagent-roles ()
  (loop for role being the hash-values of *subagent-roles* collect role))

(register-subagent-role
 "investigator"
 :description "Read-only repository investigation and review."
 :system-prompt "You are an investigator working for a host agent. Gather evidence with your read-only tools, then finish with a concise, evidence-backed report. Do not address the end user and do not modify files.")

;;; ------------------------------------------------------------------
;;; Task record and state machine

(defparameter *subagent-task-transitions*
  '((:queued :running :cancelled :failed)
    (:running :succeeded :failed :cancelled :unknown)
    (:unknown :failed :cancelled))
  "State -> permitted next states.  SUCCEEDED, FAILED and CANCELLED are terminal.")

(define-condition invalid-subagent-transition (cl-agent-error)
  ((from :initarg :from :reader transition-from)
   (to :initarg :to :reader transition-to))
  (:report (lambda (c s)
             (format s "Invalid subagent task transition ~s -> ~s."
                     (transition-from c) (transition-to c)))))

(defclass subagent-task ()
  ((id :initarg :id :reader subagent-task-id)
   (state :initform :queued :accessor subagent-task-state)
   (contract :initarg :contract :accessor subagent-task-contract)
   (job :initform nil :accessor subagent-task-job)
   (result :initform nil :accessor subagent-task-result
           :documentation "Inert result plist once terminal.")
   (note :initform nil :accessor subagent-task-note
         :documentation "Human-readable reason for the terminal state.")
   (created-at :initform (get-universal-time) :reader subagent-task-created-at)
   (started-at :initform nil :accessor subagent-task-started-at)
   (finished-at :initform nil :accessor subagent-task-finished-at)
   (frontend :initarg :frontend :initform nil :accessor subagent-task-frontend
             :documentation "The parent session's frontend, told about changes.")
   (progress :initform nil :accessor subagent-task-progress
             :documentation "Latest plist the child reported (:REQUESTS :TOOL-CALLS
:TOKENS :ACTIVITY), read from the task's progress file.")
   (poller-stop :initform nil :accessor subagent-task-poller-stop)
   (lock :initform (bordeaux-threads:make-lock "subagent task") :reader subagent-task-lock)))

(defmethod print-object ((task subagent-task) stream)
  (print-unreadable-object (task stream :type t)
    (format stream "~a ~(~a~)" (subagent-task-id task) (subagent-task-state task))))

(defvar *subagent-tasks* (make-hash-table :test 'equal))
(defvar *subagent-tasks-lock* (bordeaux-threads:make-lock "subagent task table"))
(defvar *subagent-task-counter* 0)

(defun subagent-task-terminal-p (task)
  (member (subagent-task-state task) '(:succeeded :failed :cancelled)))

(defun subagent-task-snapshot (task)
  "Inert, printable description of TASK suitable for hooks, events, tools and UIs."
  (let* ((contract (subagent-task-contract task))
         (result (subagent-task-result task))
         (progress (subagent-task-progress task))
         (description (getf contract :task)))
    (list :id (subagent-task-id task)
          :state (subagent-task-state task)
          :role (getf contract :role)
          :profile (getf contract :profile)
          :model (getf (getf contract :provider) :model)
          :tools (getf contract :tools)
          :depth (getf contract :depth)
          :description (and (stringp description)
                            (let ((line (substitute #\Space #\Newline description)))
                              (if (> (length line) 100) (subseq line 0 100) line)))
          :activity (getf progress :activity)
          :note (subagent-task-note task)
          :created-at (subagent-task-created-at task)
          :started-at (subagent-task-started-at task)
          :finished-at (subagent-task-finished-at task)
          :requests (or (getf result :requests) (getf progress :requests))
          :tool-calls (or (getf result :tool-calls) (getf progress :tool-calls))
          :tokens (or (getf result :total-tokens) (getf progress :tokens)))))

(defun publish-subagent-task (task)
  (publish-component :subagent-task (subagent-task-id task)
                     :effects (list :process)
                     :status (subagent-task-state task)
                     :metadata (subagent-task-snapshot task)))

(defun %apply-subagent-transition (task next note)
  "Set NEXT on TASK (lock held), then notify.  Returns T."
  (setf (subagent-task-state task) next)
  (when note (setf (subagent-task-note task) note))
  (when (eq next :running)
    (setf (subagent-task-started-at task) (get-universal-time)))
  (when (member next '(:succeeded :failed :cancelled))
    (setf (subagent-task-finished-at task) (get-universal-time)
          (getf (subagent-task-progress task) :activity) nil))
  t)

(defun notify-subagent-transition (task)
  (let ((snapshot (subagent-task-snapshot task)))
    (ignore-errors (publish-subagent-task task))
    (emit-event :subagent-task-transition
                :component (component-id :subagent-task (subagent-task-id task))
                :payload snapshot)
    (run-hook :subagent-task-transition snapshot)
    (let ((frontend (subagent-task-frontend task)))
      (when frontend
        (ignore-errors (ui-subagent-event frontend snapshot))
        (refresh-subagent-ui task)))))

(defun transition-subagent-task (task next &key note)
  "Strictly move TASK to NEXT or signal INVALID-SUBAGENT-TRANSITION."
  (bordeaux-threads:with-lock-held ((subagent-task-lock task))
    (let ((from (subagent-task-state task)))
      (unless (member next (cdr (assoc from *subagent-task-transitions*)))
        (error 'invalid-subagent-transition :from from :to next))
      (%apply-subagent-transition task next note)))
  (notify-subagent-transition task)
  task)

(defun settle-subagent-task (task next &key note result)
  "Like TRANSITION-SUBAGENT-TASK, but a no-op returning NIL when TASK is already
terminal or NEXT is not permitted.  Used where two parties race to finish a
task (the job body, cancellation, a timeout): the first writer wins."
  (let ((moved nil))
    (bordeaux-threads:with-lock-held ((subagent-task-lock task))
      (when (member next (cdr (assoc (subagent-task-state task) *subagent-task-transitions*)))
        (when result (setf (subagent-task-result task) result))
        (setf moved (%apply-subagent-transition task next note))))
    (when moved (notify-subagent-transition task))
    moved))

(defun find-subagent-task (id)
  (or (gethash id *subagent-tasks*)
      (error "No subagent task named ~s." id)))

(defun list-subagent-tasks ()
  (bordeaux-threads:with-lock-held (*subagent-tasks-lock*)
    (sort (loop for task being the hash-values of *subagent-tasks* collect task)
          #'< :key #'subagent-task-created-at)))

;;; ------------------------------------------------------------------
;;; Visibility: what frontends are shown

(defun subagent-panel-snapshots (frontend &key (linger *subagent-panel-linger-seconds*))
  "Snapshots of FRONTEND's live subagents plus those finished within LINGER seconds."
  (let ((now (get-universal-time)))
    (loop for task in (list-subagent-tasks)
          when (and (eq (subagent-task-frontend task) frontend)
                    (or (not (subagent-task-terminal-p task))
                        (<= (- now (or (subagent-task-finished-at task) now)) linger)))
            collect (subagent-task-snapshot task))))

(defun refresh-subagent-ui (task)
  "Tell TASK's frontend the visible set of subagents changed.  Never signals."
  (let ((frontend (subagent-task-frontend task)))
    (when frontend
      (ignore-errors (ui-subagents-updated frontend (subagent-panel-snapshots frontend))))))

(defun subagent-state-glyph (state)
  (case state (:queued "○") (:running "●") (:succeeded "✓") (:failed "✗")
    (:cancelled "⊘") (t "?")))

(defun format-duration-seconds (seconds)
  (let ((seconds (max 0 seconds)))
    (if (>= seconds 60) (format nil "~dm~2,'0ds" (floor seconds 60) (mod seconds 60))
        (format nil "~ds" seconds))))

(defun format-subagent-line (snapshot &optional (now (get-universal-time)))
  "One-line, Claude-Code-style description of a subagent snapshot."
  (let* ((started (getf snapshot :started-at))
         (elapsed (and started (- (or (getf snapshot :finished-at) now) started)))
         (state (getf snapshot :state)))
    (format nil "~a ~a~@[ (~a)~] · ~(~a~)~@[ ~a~] · ~d tool call~:p~@[ · ~d token~:p~]~@[ · ~a~]"
            (subagent-state-glyph state) (getf snapshot :id) (getf snapshot :role)
            state (and elapsed (format-duration-seconds elapsed))
            (or (getf snapshot :tool-calls) 0)
            (let ((tokens (getf snapshot :tokens))) (and tokens (plusp tokens) tokens))
            (or (and (eq state :running) (getf snapshot :activity))
                (and (member state '(:failed :cancelled)) (getf snapshot :note))
                (getf snapshot :description)))))

(defun format-subagent-event (snapshot)
  (format nil "[subagent] ~a~@[ — ~a~]"
          (format-subagent-line snapshot)
          (and (eq (getf snapshot :state) :queued) (getf snapshot :model))))

;;; Child progress reporting: the child is busy inside one blocking worker
;;; request, so it publishes progress to a small file the host polls.

(defclass progress-subagent-frontend (agent-frontend)
  ((path :initarg :path :initform nil :reader progress-frontend-path)
   (progress :initform nil :accessor progress-frontend-progress))
  (:documentation "Silent frontend for a child process that records progress
(tool calls, current tool, request and token totals) to the task's progress
file.  It never writes to stdout, which carries the worker protocol."))

(defun write-subagent-progress (frontend &rest changes)
  (let ((path (progress-frontend-path frontend)))
    (loop for (key value) on changes by #'cddr
          do (setf (getf (progress-frontend-progress frontend) key) value))
    (when path
      (ignore-errors
       (write-string-atomically
        path (let ((*print-readably* nil) (*print-pretty* nil) (*package* (find-package :cl-agent)))
               (prin1-to-string (progress-frontend-progress frontend))))))))

(defmethod ui-assistant-text ((frontend progress-subagent-frontend) text)
  (declare (ignore text)) (values))
(defmethod ui-system ((frontend progress-subagent-frontend) text)
  (declare (ignore text)) (values))
(defmethod ui-tool-finished ((frontend progress-subagent-frontend) tool-name arguments result)
  (declare (ignore tool-name arguments result))
  (write-subagent-progress frontend :activity nil))
(defmethod ui-tool-started ((frontend progress-subagent-frontend) tool-name arguments)
  (write-subagent-progress frontend
                           :activity (let ((summary (substitute #\Space #\Newline
                                                                (tool-call-summary tool-name arguments))))
                                       (if (> (length summary) 80) (subseq summary 0 80) summary))
                           :tool-calls (1+ (or (getf (progress-frontend-progress frontend) :tool-calls) 0))))
(defmethod ui-stats-updated ((frontend progress-subagent-frontend) stats)
  (write-subagent-progress frontend :requests (getf stats :requests)
                                    :tokens (getf stats :total-tokens)))

(defun subagent-progress-pathname (id)
  (merge-pathnames (format nil "workers/progress/~a.sexp" id) *config-directory*))

(defun poll-subagent-progress (task)
  "Read TASK's progress file; refresh the UI when it changed.  Never signals."
  (ignore-errors
   (let* ((path (getf (subagent-task-contract task) :progress-file))
          (progress (and path (probe-file path)
                         (with-open-file (in path)
                           (let ((*read-eval* nil) (*package* (find-package :cl-agent)))
                             (read in nil nil))))))
     (when (and (consp progress) (not (equal progress (subagent-task-progress task))))
       (setf (subagent-task-progress task) progress)
       (refresh-subagent-ui task)))))

(defun start-subagent-progress-poller (task)
  (bordeaux-threads:make-thread
   (lambda ()
     (loop until (subagent-task-poller-stop task)
           do (sleep 0.5) (poll-subagent-progress task)))
   :name (format nil "~a progress" (subagent-task-id task))))

;;; ------------------------------------------------------------------
;;; Contract construction

(defun resolve-subagent-tools (requested role)
  "Return the tool-name list for a child.  REQUESTED (caller) wins over ROLE,
which wins over the defaults; names outside *SUBAGENT-GRANTABLE-TOOLS* are
refused so a model cannot grant a child more authority than the host allows."
  (let* ((names (or requested (getf role :tools) *subagent-default-tools*))
         (denied (remove-if (lambda (name) (member name *subagent-grantable-tools* :test #'string=))
                            names)))
    (when denied
      (error "Subagents may not be granted: ~{~a~^, ~}. Grantable tools: ~{~a~^, ~}."
             denied *subagent-grantable-tools*))
    (remove-duplicates names :test #'string= :from-end t)))

(defun build-subagent-contract (parent task system &key role profile tools
                                                      max-tool-iterations model)
  "Build the inert contract for a child of PARENT, then pass it through the
:BEFORE-SUBAGENT-START chain hook.  Signals when the depth limit is reached, the
profile is unknown, or the provider cannot be rebuilt in a child."
  (when (>= (session-subagent-depth parent) (session-max-subagent-depth parent))
    (error "Nesting depth ~d has reached the configured limit."
           (session-max-subagent-depth parent)))
  (let* ((role-plist (and role (or (find-subagent-role role)
                                   (error "Unknown subagent role ~s. Known roles: ~{~a~^, ~}."
                                          role (mapcar (lambda (r) (getf r :name))
                                                       (list-subagent-roles))))))
         (profile-name (or profile (getf role-plist :profile)))
         (selected (and profile-name (or (find-subagent-model-profile parent profile-name)
                                         (error "Unknown model profile ~s." profile-name))))
         (model (or model (and selected (getf selected :model))
                    (provider-model (session-provider parent))))
         (spec (or (provider-worker-spec (session-provider parent) model)
                   (error "Provider ~a cannot be rebuilt in a worker process."
                          (provider-display-name (session-provider parent)))))
         (guidance (getf selected :system-prompt))
         (base-system (or system (getf role-plist :system-prompt)
                          "You are a subagent working for a host agent. Report concisely."))
         (limit (or (and selected (getf selected :max-tool-iterations))
                    max-tool-iterations (getf role-plist :max-tool-iterations) 1000)))
    (run-hook-chain
     :before-subagent-start
     (list :version 1
           :task task
           :role (getf role-plist :name)
           :profile (getf selected :name)
           :system (if (and (stringp guidance) (plusp (length (string-trim " " guidance))))
                       (format nil "~a~%~%Profile guidance:~%~a" base-system guidance)
                       base-system)
           :provider spec
           :tools (resolve-subagent-tools tools role-plist)
           :max-tool-iterations limit
           :max-seconds (or (getf role-plist :max-seconds) *subagent-default-max-seconds*)
           :depth (1+ (session-subagent-depth parent))
           :max-depth (session-max-subagent-depth parent)
           :setup-forms (getf role-plist :setup-forms)))))

;;; ------------------------------------------------------------------
;;; Child side

(defun run-subagent-worker-task (contract)
  "Entry point evaluated inside a child SBCL.  Builds a provider and a silent,
isolated session from CONTRACT, runs one agent turn, and returns an inert plist
of keywords, strings and integers."
  (dolist (source (getf contract :setup-forms))
    (let ((*read-eval* nil)) (eval (read-from-string source))))
  (let* ((spec (getf contract :provider))
         (provider (make-provider (getf spec :keyword) :model (getf spec :model)
                                  :api-key (getf spec :api-key)))
         (names (getf contract :tools))
         (tools (remove nil (mapcar #'find-tool names)))
         (missing (set-difference names (mapcar #'tool-name tools) :test #'string=)))
    (when (and (getf spec :base-url) (slot-exists-p provider 'base-url))
      (setf (slot-value provider 'base-url) (getf spec :base-url)))
    (let ((child (make-session provider
                               :frontend (make-instance 'progress-subagent-frontend
                                                        :path (getf contract :progress-file))
                               :system-prompt (getf contract :system)
                               :tools tools
                               :max-tool-iterations (getf contract :max-tool-iterations)
                               :subagent-depth (getf contract :depth)
                               :max-subagent-depth (getf contract :max-depth))))
      (setf (session-messages child)
            (append (session-messages child)
                    (list (list :role "user" :content (getf contract :task)))))
      (let ((turn (run-agent-turn child))
            (stats (session-raw-stats child)))
        (list :status :ok
              :report (or (getf turn :content) "")
              :model (provider-model provider)
              :requests (getf stats :requests)
              :tool-calls (getf stats :tool-calls)
              :total-tokens (getf stats :total-tokens)
              :missing-tools (copy-list missing))))))

;;; ------------------------------------------------------------------
;;; Host side execution

(defvar *subagent-task-pool* nil)
(defvar *subagent-task-pool-lock* (bordeaux-threads:make-lock "subagent task pool"))

(defun subagent-task-pool ()
  (or *subagent-task-pool*
      (bordeaux-threads:with-lock-held (*subagent-task-pool-lock*)
        (or *subagent-task-pool*
            (setf *subagent-task-pool*
                  (cl-jobpond:make-job-pool :name "cl-agent subagents"
                                            :maximum-concurrency *subagent-max-concurrency*
                                            :maximum-live-jobs 64
                                            :maximum-runtime-milliseconds 0))))))

(defun subagent-worker-form (contract)
  (let ((*print-readably* nil) (*print-pretty* nil) (*print-circle* nil)
        (*package* (find-package :cl-agent)))
    (format nil "(cl-agent::run-subagent-worker-task '~s)" contract)))

(defun redact-secret (text secret)
  (if (and (stringp text) (stringp secret) (plusp (length secret)))
      (let ((out text))
        (loop for pos = (search secret out) while pos
              do (setf out (concatenate 'string (subseq out 0 pos) "[redacted]"
                                        (subseq out (+ pos (length secret))))))
        out)
      text))

(defun read-worker-result (response secret)
  "Convert a worker protocol RESPONSE into an inert result plist."
  (let ((response (if (eq (first response) :response) (rest response) response)))
   (flet ((clean (text) (redact-secret text secret)))
    (if (eq (getf response :status) :ok)
        (handler-case
            (let ((*read-eval* nil) (*package* (find-package :cl-agent)))
              (let ((value (read-from-string (first (getf response :values)))))
                (if (and (consp value) (eq (getf value :status) :ok))
                    value
                    (list :status :error :message "The worker returned no result."))))
          (error (condition)
            (list :status :error :message (clean (format nil "Unreadable worker result: ~a" condition)))))
        (list :status :error
              :message (clean (or (getf response :message) "The worker failed."))
              :output (clean (getf response :output)))))))

(defun run-subagent-task-body (task)
  "Job body: run TASK's contract in its own child process, then settle it."
  (let* ((contract (subagent-task-contract task))
         (worker (subagent-task-id task))
         (secret (getf (getf contract :provider) :api-key)))
    (unless (settle-subagent-task task :running)
      (return-from run-subagent-task-body nil))
    (start-subagent-progress-poller task)
    (unwind-protect
         (let* ((response (run-subagent-worker-evaluation worker (subagent-worker-form contract)))
                (result (run-hook-chain :after-subagent-result
                                        (append (list :task-id worker)
                                                (read-worker-result response secret)))))
           (if (eq (getf result :status) :ok)
               (settle-subagent-task task :succeeded :result result)
               (settle-subagent-task task :failed :result result
                                     :note (getf result :message))))
      (setf (subagent-task-poller-stop task) t)
      (poll-subagent-progress task)
      (ignore-errors (stop-subagent-worker worker))
      (let ((path (getf contract :progress-file)))
        (when path (ignore-errors (delete-file path)))))))

(defun start-subagent-task (parent task system &rest options &key role profile tools
                                                              max-tool-iterations model)
  "Admit a new subagent task and return it immediately; it runs concurrently."
  (declare (ignore role profile tools max-tool-iterations model))
  (let* ((contract (apply #'build-subagent-contract parent task system options))
         (id (bordeaux-threads:with-lock-held (*subagent-tasks-lock*)
               (format nil "subagent-~d" (incf *subagent-task-counter*))))
         (record (progn
                   (unless (getf contract :progress-file)
                     (setf (getf contract :progress-file)
                           (namestring (subagent-progress-pathname id))))
                   (make-instance 'subagent-task :id id :contract contract
                                                 :frontend (session-frontend parent)))))
    (bordeaux-threads:with-lock-held (*subagent-tasks-lock*)
      (setf (gethash id *subagent-tasks*) record))
    (notify-subagent-transition record)
    (handler-case
        (setf (subagent-task-job record)
              (cl-jobpond:job-pool-submit
               (subagent-task-pool)
               (lambda (job) (declare (ignore job)) (run-subagent-task-body record))
               :name id
               :maximum-runtime-milliseconds
               (* 1000 (or (getf contract :max-seconds) *subagent-default-max-seconds*))))
      (error (condition)
        (settle-subagent-task record :failed :note (format nil "Not admitted: ~a" condition))
        (error condition)))
    record))

(defun reconcile-subagent-task (task)
  "Make TASK's state agree with its job after an abort or timeout."
  (let ((job (subagent-task-job task)))
    (when (and job (not (subagent-task-terminal-p task)) (cl-jobpond:job-terminal-p job))
      (let* ((snapshot (cl-jobpond:job-snapshot job))
             (reason (getf snapshot :cancellation-reason)))
        (cond ((eq reason :timeout)
               (settle-subagent-task task :failed :note "The task exceeded its time limit."))
              ((member (getf snapshot :state) '(:aborted :failed))
               (settle-subagent-task task (if (eq (getf snapshot :state) :failed) :failed :cancelled)
                                     :note (or (getf snapshot :condition-report)
                                               (format nil "Stopped (~(~a~))." reason)))))))
    task))

(defun wait-subagent-task (task &key timeout)
  "Wait up to TIMEOUT seconds (NIL: forever).  Returns (values TASK TERMINAL-P)."
  (when (subagent-task-job task)
    (cl-jobpond:job-await (subagent-task-job task) :timeout-seconds timeout))
  (reconcile-subagent-task task)
  (values task (and (subagent-task-terminal-p task) t)))

(defun cancel-subagent-task (task &key (reason :cancelled))
  "Cancel TASK: stop its job, kill its child process, and mark it cancelled."
  (when (subagent-task-job task)
    (cl-jobpond:job-cancel (subagent-task-job task) :reason reason))
  (ignore-errors (stop-subagent-worker (subagent-task-id task)))
  (setf (subagent-task-poller-stop task) t)
  (settle-subagent-task task :cancelled :note (format nil "Cancelled (~(~a~))." reason))
  task)

(defun format-subagent-report (task)
  (let ((result (subagent-task-result task)))
    (case (subagent-task-state task)
      (:succeeded
       (format nil "Subagent report (~a, depth ~d, model ~a~@[ via profile ~a~], ~d request~:p, ~d tool call~:p~@[; unavailable tools: ~{~a~^, ~}~]):~%~a"
               (subagent-task-id task) (getf (subagent-task-contract task) :depth)
               (getf result :model) (getf (subagent-task-contract task) :profile)
               (getf result :requests) (getf result :tool-calls) (getf result :missing-tools)
               (if (plusp (length (getf result :report))) (getf result :report)
                   "The subagent stopped without a final report.")))
      (t (format nil "Subagent ~a ~(~a~)~@[: ~a~]." (subagent-task-id task)
                 (subagent-task-state task) (subagent-task-note task))))))

(defun run-subagent-in-worker (parent task system tools &key profile max-tool-iterations)
  "Synchronous convenience over the task runtime: start, wait, report."
  (handler-case
      (let ((record (start-subagent-task parent task system
                                         :profile profile :max-tool-iterations max-tool-iterations
                                         :tools (mapcar #'tool-name tools)
                                         :model nil)))
        (wait-subagent-task record)
        (format-subagent-report record))
    (error (condition) (format nil "Subagent was not started: ~a" condition))))

(defun stop-all-subagent-tasks ()
  "Cancel every live task; used at shutdown so no child process is orphaned."
  (dolist (task (list-subagent-tasks))
    (unless (subagent-task-terminal-p task) (cancel-subagent-task task :reason :shutdown))))

;;; ------------------------------------------------------------------
;;; Tools

(defun %task-arg (args name)
  (let ((value (jget args name)))
    (and (stringp value) (plusp (length (string-trim " " value))) value)))

(defun %task-by-arg (args)
  (let ((id (%task-arg args "task_id")))
    (unless id (error "task_id is required"))
    (find-subagent-task id)))

(define-tool start-subagent (args)
    (:description "Start an isolated subagent in its own process and return immediately with a task id. Several can run at once. It runs a real model with only the tools you grant (tools: names from the grantable set; default is read-only investigation). Use wait-subagent to collect its report. Prefer this over delegate-task when you can do other work, or launch several independent investigations, in parallel."
     :effects (list :process)
     :parameters (jobj "type" "object"
                       "properties" (jobj "task" (jobj "type" "string" "description" "What the subagent must do.")
                                          "system_prompt" (jobj "type" "string" "description" "Optional role instructions; defaults to the role's prompt.")
                                          "role" (jobj "type" "string" "description" "Optional registered subagent role.")
                                          "profile" (jobj "type" "string" "description" "Optional model-routing profile.")
                                          "tools" (jobj "type" "array" "items" (jobj "type" "string")
                                                        "description" "Tool names to grant."))
                       "required" (list "task")))
  (unless *current-session* (error "start-subagent is available only while an agent session is running"))
  (let ((tools (jget args "tools")))
    (unless (or (null tools) (and (listp tools) (every #'stringp tools)))
      (error "tools must be an array of strings"))
    (unless (%task-arg args "task") (error "task must be a non-empty string"))
    (let ((record (start-subagent-task *current-session* (jget args "task")
                                       (%task-arg args "system_prompt")
                                       :role (%task-arg args "role")
                                       :profile (%task-arg args "profile")
                                       :tools tools)))
      (format nil "Started ~a (~(~a~)). Collect it with wait-subagent." (subagent-task-id record)
              (subagent-task-state record)))))

(define-tool wait-subagent (args)
    (:description "Wait for a subagent task to finish (up to timeout_seconds, default 60) and return its report, or its current state if it is still running."
     :parameters (jobj "type" "object"
                       "properties" (jobj "task_id" (jobj "type" "string")
                                          "timeout_seconds" (jobj "type" "integer" "minimum" 0))
                       "required" (list "task_id")))
  (let ((timeout (jget args "timeout_seconds" 60)))
    (unless (and (integerp timeout) (>= timeout 0)) (error "timeout_seconds must be a non-negative integer"))
    (multiple-value-bind (record terminal-p) (wait-subagent-task (%task-by-arg args) :timeout timeout)
      (if terminal-p
          (format-subagent-report record)
          (format nil "~a is still ~(~a~)." (subagent-task-id record) (subagent-task-state record))))))

(define-tool cancel-subagent (args)
    (:description "Cancel a running or queued subagent task and kill its process."
     :effects (list :process)
     :parameters (jobj "type" "object" "properties" (jobj "task_id" (jobj "type" "string"))
                       "required" (list "task_id")))
  (format-subagent-report (cancel-subagent-task (%task-by-arg args))))

(define-tool list-subagents (args)
    (:description "List subagent tasks with their state, role, model and tools, plus the registered roles and grantable tools."
     :parameters (jobj "type" "object" "properties" (jobj) "required" :empty-array))
  (format nil "Tasks:~%~{~a~^~%~}~%Roles: ~{~a~^, ~}~%Grantable tools: ~{~a~^, ~}"
          (or (mapcar (lambda (task) (let ((s (subagent-task-snapshot task)))
                                       (format nil "~a ~(~a~) role=~a model=~a tools=~{~a~^,~}"
                                               (getf s :id) (getf s :state) (getf s :role)
                                               (getf s :model) (getf s :tools))))
                      (list-subagent-tasks))
              (list "none"))
          (mapcar (lambda (r) (getf r :name)) (list-subagent-roles))
          *subagent-grantable-tools*))
