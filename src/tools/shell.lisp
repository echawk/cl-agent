;;;; tools/shell.lisp -- bounded shell execution and managed background jobs.
(in-package :cl-agent)

(defclass shell-job ()
  ((id :initarg :id :reader shell-job-id) (process :initarg :process :reader shell-job-process)
   (output :initarg :output :reader shell-job-output) (error-output :initarg :error-output :reader shell-job-error-output)
   (started-at :initarg :started-at :reader shell-job-started-at) (expected :initarg :expected :reader shell-job-expected)
   (finished-p :initform nil :accessor shell-job-finished-p) (result :initform nil :accessor shell-job-result)))

(defvar *shell-jobs* (make-hash-table :test 'equal))
(defvar *shell-job-counter* 0)
(defvar *shell-job-lock* (bordeaux-threads:make-lock "shell jobs"))
;; TCP-style EWMA error model: agents' estimates improve through feedback.
(defparameter *shell-duration-bias* 0d0)
(defparameter *shell-duration-deviation* 1d0)
(defparameter *shell-default-expected-seconds* 10)
(defparameter *shell-maximum-seconds* 300)

(defun shell-now () (/ (get-internal-real-time) internal-time-units-per-second))
(defun shell-elapsed (job) (- (shell-now) (shell-job-started-at job)))
(defun shell-learn (expected actual)
  (let* ((error (- actual expected)) (old *shell-duration-bias*))
    (setf *shell-duration-deviation* (+ (* .75d0 *shell-duration-deviation*) (* .25d0 (abs (- error old))))
          *shell-duration-bias* (+ (* .875d0 old) (* .125d0 error)))))
(defun shell-warning-delay (expected explicit)
  (min *shell-maximum-seconds* (or explicit (ceiling (+ expected (max 1d0 *shell-duration-deviation*))))))

(defun required-shell-command (arguments)
  "Return the required command string from a tool ARGUMENTS object.

Keep absence, a wrong JSON type, and an empty command distinct so a model
calling CALL-TOOL directly gets actionable feedback even when it bypasses the
agent loop's JSON-Schema validation."
  (unless (hash-table-p arguments)
    (error "shell arguments must be a JSON object"))
  (multiple-value-bind (command presentp) (gethash "command" arguments)
    (unless presentp
      (error "shell tool received no \"command\" argument"))
    (unless (stringp command)
      (error "shell command must be a plain string"))
    (unless (plusp (length (string-trim " " command)))
      (error "shell command must not be empty"))
    command))

(defun launch-shell-job (command expected)
  (unless (and (stringp command) (plusp (length (string-trim " " command))))
    (error "shell command must be a non-empty string"))
  (unless (and (integerp expected) (plusp expected)) (error "expected_seconds must be a positive integer"))
  (bordeaux-threads:with-lock-held (*shell-job-lock*)
    (let* ((id (format nil "shell-~d" (incf *shell-job-counter*)))
           ;; Pass an argv rather than asking UIOP for an additional wrapper
           ;; shell. This makes the tracked process the command shell itself,
           ;; so normal simple commands (including `sleep`) are reaped when a
           ;; managed timeout terminates it.
           (process (uiop:launch-program (list "/bin/sh" "-c" command) :output :stream :error-output :stream))
           (job (make-instance 'shell-job :id id :process process :output (uiop:process-info-output process)
                               :error-output (uiop:process-info-error-output process) :started-at (shell-now) :expected expected)))
      (setf (gethash id *shell-jobs*) job) job)))
(defun find-shell-job (id) (or (gethash id *shell-jobs*) (error "No managed shell job named ~s" id)))

(defun finish-shell-job (job &key interrupted)
  (unless (shell-job-finished-p job)
    (let* ((code (uiop:wait-process (shell-job-process job)))
           (out (or (ignore-errors (uiop:slurp-stream-string (shell-job-output job))) ""))
           (err (or (ignore-errors (uiop:slurp-stream-string (shell-job-error-output job))) ""))
           (elapsed (shell-elapsed job)))
      (ignore-errors (close (shell-job-output job))) (ignore-errors (close (shell-job-error-output job)))
      (shell-learn (shell-job-expected job) elapsed)
      (setf (shell-job-finished-p job) t
            (shell-job-result job)
            (format nil "~:[~;INTERRUPTED: command exceeded its deadline and was terminated. Check for an infinite loop; use start-shell-job for intentional long work.~%~]Job: ~a~%Elapsed: ~,2fs (estimate ~ds; learned deviation ~,2fs)~%Exit code: ~d~%~a"
                    interrupted (shell-job-id job) elapsed (shell-job-expected job) *shell-duration-deviation* code
                    (concatenate 'string out err)))))
  (shell-job-result job))
(defun stop-shell-job (id &key urgent)
  (let ((job (find-shell-job id)))
    (if (shell-job-finished-p job) (shell-job-result job)
        (progn (uiop:terminate-process (shell-job-process job) :urgent urgent) (finish-shell-job job :interrupted t)))))
(defun shell-job-status (id)
  (let ((job (find-shell-job id)))
    (if (shell-job-finished-p job) (format nil "Job ~a finished.~%~a" id (shell-job-result job))
        (format nil "Job ~a is running for ~,2fs (estimate ~ds)." id (shell-elapsed job) (shell-job-expected job)))))
(defun wait-for-shell-job (job deadline)
  (loop while (uiop:process-alive-p (shell-job-process job))
        when (>= (shell-elapsed job) deadline) do (return (stop-shell-job (shell-job-id job)))
        do (sleep .05))
  (finish-shell-job job))

(define-tool shell (args)
    (:description "Run a shell command with loop detection. Supply expected_seconds whenever possible. Commands are interrupted at one learned standard deviation past that estimate, or at explicit warning_after_seconds. An interruption is feedback to inspect for a loop; use managed background jobs for intentional long work."
     :parameters (jobj "type" "object" "properties"
                       (jobj "command" (jobj "type" "string") "reason" (jobj "type" "string") "result_use" (jobj "type" "string")
                              "expected_seconds" (jobj "type" "integer" "minimum" 1) "warning_after_seconds" (jobj "type" "integer" "minimum" 1))
                       "required" (list "command" "reason" "result_use")))
  (let* ((expected (jget args "expected_seconds" *shell-default-expected-seconds*))
         (job (launch-shell-job (required-shell-command args) expected)))
    (wait-for-shell-job job (shell-warning-delay expected (jget args "warning_after_seconds")))))

(define-tool start-shell-job (args)
    (:description "Start a managed background shell job. Then use shell-job-status, collect-shell-job, or stop-shell-job instead of ps/kill."
     :parameters (jobj "type" "object" "properties" (jobj "command" (jobj "type" "string") "expected_seconds" (jobj "type" "integer" "minimum" 1)) "required" (list "command" "expected_seconds")))
  (let ((job (launch-shell-job (required-shell-command args) (jget args "expected_seconds"))))
    (format nil "Started managed shell job ~a." (shell-job-id job))))
(define-tool shell-job-status (args)
    (:description "Check a managed background shell job by id." :parameters (jobj "type" "object" "properties" (jobj "id" (jobj "type" "string")) "required" (list "id")))
  (shell-job-status (jget args "id")))
(define-tool collect-shell-job (args)
    (:description "Collect output from a finished managed job; report status without blocking if it still runs." :parameters (jobj "type" "object" "properties" (jobj "id" (jobj "type" "string")) "required" (list "id")))
  (let ((job (find-shell-job (jget args "id"))))
    (if (uiop:process-alive-p (shell-job-process job)) (shell-job-status (shell-job-id job)) (finish-shell-job job))))
(define-tool stop-shell-job (args)
    (:description "Terminate a managed background job by id instead of using ps/kill." :parameters (jobj "type" "object" "properties" (jobj "id" (jobj "type" "string") "urgent" (jobj "type" "boolean")) "required" (list "id")))
  (stop-shell-job (jget args "id") :urgent (jget args "urgent" nil)))
