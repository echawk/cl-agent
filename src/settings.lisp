;;;; settings.lisp -- typed runtime settings backed by Setinka and SEXP-STORE.

(in-package :cl-agent)

(defparameter *agent-setting-registry* (setinka:make-setting-registry)
  "The settings owned by cl-agent rather than by a dependency.")

(setinka:define-setting :compaction-percent (setinka:integer-setting :registry *agent-setting-registry*)
  :label "Compaction threshold" :group :context :scope :durable
  :documentation "Percentage of the provider context window that triggers automatic compaction."
  :environment "CL_AGENT_COMPACTION_PERCENT" :minimum 0 :maximum 100 :default 80)

(setinka:define-setting :max-tool-iterations (setinka:integer-setting :registry *agent-setting-registry*)
  :label "Tool-call limit" :group :agent :scope :durable
  :documentation "Maximum tool-call rounds permitted in one agent turn."
  :environment "CL_AGENT_MAX_TOOL_ITERATIONS" :minimum 1 :maximum 10000 :default 1000)

(setinka:define-setting :orchestration-mode (setinka:choice-setting :registry *agent-setting-registry*)
  :label "Orchestration mode" :group :agent :scope :durable :type 'keyword
  :documentation "Whether the agent answers directly, plans first, or plans and reviews."
  :environment "CL_AGENT_ORCHESTRATION_MODE"
  :options '(:direct :plan :plan-review) :default :direct)

(setinka:define-setting :max-subagent-depth (setinka:integer-setting :registry *agent-setting-registry*)
  :label "Subagent depth" :group :workers :scope :durable
  :documentation "Maximum nesting depth permitted for delegated subagents."
  :environment "CL_AGENT_MAX_SUBAGENT_DEPTH" :minimum 0 :maximum 16 :default 1)

(defun agent-settings-path ()
  (merge-pathnames "state/settings.sexp" *config-directory*))

(defun agent-settings-lock-path ()
  (merge-pathnames "state/settings.lock" *config-directory*))

(defun agent-settings-record-p (record)
  "Recognize one versioned, data-only settings record."
  (and (eq (first record) :cl-agent-settings)
       (eql (getf (rest record) :version) 1)
       (let ((values (getf (rest record) :values)))
         (and (listp values) (evenp (length values))
              (loop for (name value) on values by #'cddr
                    always (and (keywordp name)
                                (sexp-store:record-finite-p value)))))))

(defun make-agent-settings-transaction ()
  "Create the locked snapshot transaction used by every settings configuration."
  (make-instance 'sexp-store:snapshot-store
                 :pathname (agent-settings-path)
                 :lock-pathname (agent-settings-lock-path)
                 :initial-state (lambda () nil)
                 :validator #'agent-settings-record-p
                 :decoder (lambda (record) (copy-list (getf (rest record) :values)))
                 :encoder (lambda (values)
                            (list :cl-agent-settings :version 1 :values values))))

(defclass agent-settings-store (setinka:setting-store)
  ((transaction :initarg :transaction :reader agent-settings-store-transaction)))

(defmethod setinka:store-read-values ((store agent-settings-store) configuration)
  (declare (ignore configuration))
  (sexp-store:store-read (agent-settings-store-transaction store)))

(defmethod setinka:store-write-value
    ((store agent-settings-store) configuration name value)
  (declare (ignore configuration))
  (sexp-store:store-transact
   (agent-settings-store-transaction store)
   (lambda (values)
     (let ((updated (copy-list values)))
       (setf (getf updated name) value)
       (values updated value t)))))

(defun make-agent-settings-store ()
  (make-instance 'agent-settings-store :transaction (make-agent-settings-transaction)))

(defun settings-overrides-from-config (legacy-config)
  "Map compatible config.lisp keys into the typed settings registry."
  (let ((overrides nil)
        (threshold (config-value legacy-config :context-compaction-threshold nil)))
    (when threshold
      (unless (and (numberp threshold) (<= 0 threshold 1))
        (error ":CONTEXT-COMPACTION-THRESHOLD must be a number from 0 to 1"))
      (setf overrides (list* :compaction-percent (round (* threshold 100)) overrides)))
    (dolist (mapping '((:max-tool-iterations . :max-tool-iterations)
                       (:orchestration-mode . :orchestration-mode)
                       (:max-subagent-depth . :max-subagent-depth)))
      (let ((value (config-value legacy-config (car mapping) nil)))
        (when value (setf overrides (list* (cdr mapping) value overrides)))))
    overrides))

(defun load-agent-settings (&optional legacy-config)
  "Load typed settings with config.lisp compatibility overrides and durable state."
  (setinka:configuration-load
   :registry *agent-setting-registry*
   :store (make-agent-settings-store)
   :overrides (settings-overrides-from-config legacy-config)))

(defun setting-percent->threshold (percent)
  (/ percent 100.0))

(defun session-setting-value (session name)
  (setinka:config name (session-settings session)))

(defun update-session-from-setting (session setting value)
  "Apply a live Setinka setting update to SESSION's existing mechanics."
  (case (setinka:setting-name setting)
    (:compaction-percent
     (setf (session-context-compaction-threshold session) (setting-percent->threshold value)))
    (:max-tool-iterations (setf (session-max-tool-iterations session) value))
    (:orchestration-mode (setf (session-orchestration-mode session) value))
    (:max-subagent-depth (setf (session-max-subagent-depth session) value)))
  session)

(defun install-session-settings-listener (session)
  (setinka:configuration-add-listener
   (session-settings session)
   (lambda (configuration setting old new)
     (declare (ignore configuration old))
     (update-session-from-setting session setting new)))
  session)

(defun format-session-settings (session)
  "Return the settings reflection view used by the /settings command."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (setting)
                    (let ((name (setinka:setting-name setting)))
                      (format nil "~(~a~): ~a [~(~a~)] — ~a"
                              name
                              (setinka:setting-render-value setting
                                                            (session-setting-value session name))
                              (or (setinka:configuration-setting-source
                                   (session-settings session) name) :default)
                              (setinka:setting-documentation setting))))
                  (setinka:settings-list *agent-setting-registry*))))

(defun parse-session-setting-name (text)
  "Resolve a user-provided setting name to a registered keyword."
  (let ((name (intern (string-upcase (substitute #\- #\_ text)) :keyword)))
    (setinka:find-setting name *agent-setting-registry*)
    name))
