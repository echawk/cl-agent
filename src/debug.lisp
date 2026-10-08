;;;; debug.lisp -- live failure handling around tool calls, via lambda-debugger.
;;;;
;;;; Every tool handler runs inside LAMBDA-DEBUGGER:CALL-WITH-DEBUGGER.  An
;;;; unhandled ERROR is selected while its stack is still live, which gives us
;;;; three things the old flatten-to-a-string path could not:
;;;;
;;;;   * a detached, journaled RECEIPT (condition type and report, bounded
;;;;     backtrace, the restarts that were available), readable later by the
;;;;     user or the model (list-failures / inspect-failure) and by other
;;;;     processes, since receipts are files;
;;;;   * a DECISION point, :TOOL-FAILURE, a chain hook that may choose a
;;;;     recovery (abort, retry, use a restart, return replacement values) with
;;;;     no model round trip;
;;;;   * policies the agent itself can set (set-failure-recovery).
;;;;
;;;; The default decision is to abort, which preserves the previous behaviour
;;;; exactly: the model sees "Error running TOOL: ...", now with a receipt id.
;;;; Non-error conditions (job cancellation, interrupts, stack exhaustion) are
;;;; never captured; they pass through untouched.

(in-package :cl-agent)

(defvar *debugger-enabled* t
  "When NIL, tool handlers run under a plain HANDLER-CASE, as before the debugger.")

(defvar *failure-retry-limit* 3
  "Hard ceiling on retries of one tool call, whatever a policy or hook requests.")

(defvar *failure-receipts* nil "Receipts recorded in this process, newest first.")
(defvar *failure-receipts-lock* (bordeaux-threads:make-lock "failure receipts"))
(defparameter *failure-receipt-memory-limit* 200)

(defvar *failure-recovery-policies* (make-hash-table :test 'equal)
  "Tool name -> plist (:ACTION :ABORT/:RETRY :MAX-RETRIES n), set by set-failure-recovery.")

;;; ------------------------------------------------------------------
;;; Receipts

(defun failure-receipt-directory ()
  (merge-pathnames "debugger/receipts/" *config-directory*))

(defun failure-receipt-pathname (id)
  (merge-pathnames (format nil "~a.sexp" id) (failure-receipt-directory)))

(defun safe-failure-id-p (id)
  "Receipt ids name files, so only a conservative alphabet is accepted."
  (and (stringp id) (<= 1 (length id) 80)
       (every (lambda (c) (or (alphanumericp c) (find c "-_"))) id)))

(defun allocate-failure-receipt-id ()
  (idsmall:identifier-generate
   :namespace :cl-agent-failure
   :occupied-p (lambda (identifier) (probe-file (failure-receipt-pathname identifier)))))

(defun bounded-text (value &optional (limit 600))
  (let ((text (substitute #\Space #\Newline (princ-to-string value))))
    (if (> (length text) limit) (concatenate 'string (subseq text 0 limit) "…") text)))

(defun arguments-summary (arguments)
  "Bounded JSON of a tool call's arguments for a receipt; never signals."
  (or (ignore-errors (bounded-text (json-encode arguments) 800)) "<unprintable arguments>"))

(defun persist-failure-receipt (receipt)
  "Write RECEIPT (a plist of printable data) atomically; return it.  Never signals."
  (ignore-errors
   (write-string-atomically
    (failure-receipt-pathname (getf receipt :id))
    (let ((*print-readably* nil) (*print-pretty* t) (*print-right-margin* 100)
          (*package* (find-package :cl-agent)))
      (prin1-to-string receipt))))
  receipt)

(defun remember-failure-receipt (receipt)
  (bordeaux-threads:with-lock-held (*failure-receipts-lock*)
    (setf *failure-receipts*
          (let ((all (cons receipt (remove (getf receipt :id) *failure-receipts*
                                           :key (lambda (r) (getf r :id)) :test #'equal))))
            (subseq all 0 (min (length all) *failure-receipt-memory-limit*)))))
  receipt)

(defun load-failure-receipt (id)
  "Find receipt ID in memory, else on disk (another process may have written it)."
  (when (safe-failure-id-p id)
    (or (bordeaux-threads:with-lock-held (*failure-receipts-lock*)
          (find id *failure-receipts* :key (lambda (r) (getf r :id)) :test #'equal))
        (let ((path (failure-receipt-pathname id)))
          (and (probe-file path)
               (ignore-errors
                (with-open-file (in path)
                  (let ((*read-eval* nil) (*package* (find-package :cl-agent)))
                    (read in nil nil)))))))))

(defun list-failure-receipts (&key (limit 20))
  "Most recent receipts across this and other processes, newest first."
  (let* ((files (ignore-errors (directory (merge-pathnames "*.sexp" (failure-receipt-directory)))))
         (disk (mapcar (lambda (path) (cons (or (ignore-errors (file-write-date path)) 0)
                                            (pathname-name path)))
                       files))
         (ids (mapcar #'cdr (sort disk #'> :key #'car)))
         (memory (bordeaux-threads:with-lock-held (*failure-receipts-lock*)
                   (mapcar (lambda (r) (getf r :id)) *failure-receipts*)))
         (all (remove-duplicates (append memory ids) :test #'equal :from-end t)))
    (remove nil (mapcar #'load-failure-receipt (subseq all 0 (min limit (length all)))))))

(defun format-failure-receipt-line (receipt)
  (format nil "~a  ~a  ~a: ~a  [~(~a~)~@[, ~d retr~:@p~]]"
          (getf receipt :id) (getf receipt :tool) (getf receipt :condition-type)
          (bounded-text (getf receipt :condition-report) 120)
          (or (getf receipt :decision) :abort)
          (let ((n (getf receipt :retries))) (and n (plusp n) n))))

(defun format-failure-receipt (receipt)
  "Full, human- and model-readable view of RECEIPT."
  (with-output-to-string (out)
    (format out "Failure ~a~%tool: ~a~%arguments: ~a~%condition: ~a~%report: ~a~%decision: ~(~a~)~@[ (~a)~]~%"
            (getf receipt :id) (getf receipt :tool) (getf receipt :arguments)
            (getf receipt :condition-type) (getf receipt :condition-report)
            (or (getf receipt :decision) :abort) (getf receipt :decision-note))
    (when (getf receipt :retries) (format out "retries: ~d~%" (getf receipt :retries)))
    (format out "restarts that were available:~%")
    (dolist (restart (getf receipt :restarts))
      (format out "  ~a. ~a~%" (getf restart :index) (getf restart :report)))
    (let ((metadata (getf receipt :condition-metadata)))
      (when metadata (format out "condition metadata: ~a~%" (bounded-text metadata 400))))
    (format out "backtrace (innermost first):~%")
    (dolist (frame (getf receipt :backtrace)) (format out "  ~a~%" frame))))

;;; ------------------------------------------------------------------
;;; Recovery decisions

(defun default-failure-recovery-policy (context)
  "Built-in :TOOL-FAILURE hook: apply a policy the agent or user set for this tool."
  (let ((policy (gethash (getf context :tool-name) *failure-recovery-policies*)))
    (if (and policy (null (getf context :decision)) (eq (getf policy :action) :retry)
             (<= (getf context :attempt) (or (getf policy :max-retries) 1)))
        (list* :decision :retry :decision-note "recovery policy: retry" context)
        context)))

(add-hook :tool-failure 'recovery-policy #'default-failure-recovery-policy)

(defun failure-decision->recovery (decision snapshot attempt)
  "Translate a hook DECISION into a LAMBDA-DEBUGGER recovery, or NIL to abort.

Decisions: :ABORT, :RETRY, (:RETURN-VALUES \"source\"), (:RESTART index [\"source\"]).
A retry past *FAILURE-RETRY-LIMIT* becomes an abort."
  (let ((kind (if (consp decision) (first decision) decision)))
    (case kind
      (:retry (when (<= attempt *failure-retry-limit*)
                (lambda-debugger:make-recovery :kind :retry-operation
                                               :report "Retry the tool call.")))
      (:return-values
       (lambda-debugger:make-recovery :kind :return-values
                                      :report "Return replacement values."
                                      :return-source (second decision)))
      (:restart
       (let ((target (nth (1- (or (second decision) 0)) (getf snapshot :restarts))))
         (when target
           (lambda-debugger:make-recovery :kind :invoke-restart
                                          :report "Invoke the selected restart."
                                          :restart-id (getf target :id)
                                          :argument-source (third decision)))))
      (t nil))))

(defun make-failure-receipt (id tool-name arguments snapshot attempt)
  (list :id id :tool tool-name :time (get-universal-time)
        :arguments (arguments-summary arguments)
        :condition-type (getf snapshot :condition-type)
        :condition-report (bounded-text (getf snapshot :condition-report) 2000)
        :condition-metadata (getf snapshot :condition-metadata)
        :restarts (loop for restart in (getf snapshot :restarts) for i from 1
                        collect (list :index i :report (bounded-text (getf restart :report) 200)))
        :backtrace (getf snapshot :backtrace)
        :retries (1- attempt)
        :decision :abort
        :process (ignore-errors (sb-unix:unix-getpid))))

(defun select-tool-failure-recovery (session tool-name arguments state)
  "SELECTOR for CALL-WITH-DEBUGGER.  STATE is a plist cell holding :ATTEMPT and :RECEIPT.
Journals a receipt, asks the :TOOL-FAILURE hook chain for a decision, and never
signals: any problem here degrades to aborting the call."
  (handler-case
      (let* ((snapshot (lambda-debugger:debug-session-snapshot session))
             (attempt (incf (getf (car state) :attempt 0)))
             (receipt (or (and (> attempt 1) (getf (car state) :receipt))
                          (make-failure-receipt (allocate-failure-receipt-id)
                                                tool-name arguments snapshot attempt)))
             (context (handler-case
                          (run-hook-chain :tool-failure
                                          (list :id (getf receipt :id) :tool-name tool-name
                                                :arguments arguments :attempt attempt
                                                :snapshot snapshot :decision nil))
                        (error (c)
                          (list :decision nil :decision-note
                                (format nil "decision hook failed: ~a" c)))))
             (decision (getf context :decision))
             (recovery (failure-decision->recovery decision snapshot attempt)))
        (setf (getf receipt :retries) (1- attempt)
              (getf receipt :decision) (if recovery
                                           (if (consp decision) (first decision) decision)
                                           :abort)
              (getf receipt :decision-note) (or (getf context :decision-note)
                                                (and decision (null recovery)
                                                     "decision not applicable; aborted")))
        (setf (getf (car state) :receipt) receipt)
        (persist-failure-receipt receipt)
        (remember-failure-receipt receipt)
        (emit-event :tool-failure :component (component-id :tool tool-name)
                    :payload (list :id (getf receipt :id) :decision (getf receipt :decision)
                                   :condition-type (getf receipt :condition-type)))
        recovery)
    (error () nil)))

(defun call-tool-handler-with-debugger (tool arguments)
  "Run TOOL's handler under the debugger and return its result string.

On an unrecovered failure returns the usual \"Error running NAME: ...\" text, with
the receipt id appended so the agent can call inspect-failure."
  (let* ((name (tool-name tool))
         (state (list (list :attempt 0 :receipt nil)))
         (outcome
           (lambda-debugger:call-with-debugger
            (lambda () (funcall (tool-handler tool) arguments))
            :selector (lambda (session)
                        (select-tool-failure-recovery session name arguments state))
            :condition-p (lambda (condition) (typep condition 'error))
            :operation-kind :tool
            :source (format nil "tool ~a" name)
            :retry-p t
            :return-values-p t)))
    (if (eq (lambda-debugger:outcome-status outcome) :ok)
        (let ((value (first (lambda-debugger:outcome-values outcome))))
          (if (stringp value) value (princ-to-string value)))
        (let ((receipt (getf (car state) :receipt)))
          (format nil "Error running ~a: ~a~@[~%[failure ~a — inspect-failure shows its stack and the restarts that were available]~]"
                  name (lambda-debugger:outcome-condition-report outcome)
                  (and receipt (getf receipt :id)))))))
