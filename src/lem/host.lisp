;;;; lem/host.lisp -- Lem's editor core, hosted in this image with no
;;;; display of its own (docs/lem-integration.md).
;;;;
;;;; Its frontend is LEM-HOST-DISPLAY (lem/display.lisp): Lem's own web
;;;; renderer, shown in the Code tab once a page connects.  LEM-HOST-START
;;;; runs Lem's editor thread the way
;;;; Lem's RUN-EDITOR-THREAD does, but never through LEM:LAUNCH, which would
;;;; reconfigure log4cl and the default external format for the whole
;;;; image.  It loads the user's Lem init file from Lem's own home
;;;; ($LEM_HOME, ~/.lem/ or the XDG config directory, as Lem decides),
;;;; then (lem-home)/cl-agent.lisp for settings meant only for cl-agent.
;;;;
;;;; Lem state belongs to the thread named "editor": everything else goes
;;;; through LEM-CALL, which queues a function on Lem's event queue and
;;;; waits for its result, as Lem's own MCP server does.  The host starts
;;;; lazily, on the first LEM-CALL, so building or loading cl-agent never
;;;; starts it; if it cannot start, LEM-HOST-AVAILABLE-P is false and
;;;; callers fall back.

(in-package :cl-agent)

;; Loading Lem makes (ed) start a Lem frontend; in this image it must not.
(setf sb-ext:*ed-functions*
      (remove-if (lambda (function)
                   (let ((name (nth-value 2 (function-lambda-expression function)))
                         (*package* (find-package :keyword)))
                     (search "LEM-CORE::" (prin1-to-string name))))
                 sb-ext:*ed-functions*))

;; Lisp buffers would otherwise start a micros server inside this image.
(setf lem-lisp-mode/test-api:*disable-self-connect* t)

(pushnew :cl-agent-lem *features*)

(defvar *lem-load-init-file* t
  "Whether the Lem host loads the user's Lem init file.  The environment
variable CL_AGENT_LEM_NO_INIT=1 also turns it off.")

(defvar *lem-tab-bar* nil
  "Whether the hosted Lem shows its tab bar (Lem's web frontends turn it on
by default).  The Code tab lists open files itself, so it is off; a Lem
init file that sets LEM/TABBAR:*ENABLE-TABBAR-ON-STARTUP* to T (it loads
after this is applied) or M-x toggle-tabbar brings it back.")

(defparameter *lem-call-timeout* 10
  "Seconds LEM-CALL waits for the editor thread.")

;;; --- the editor thread ---

(defvar *lem-host-lock* (bordeaux-threads:make-lock "lem-host"))
(defvar *lem-host-ready* (bordeaux-threads:make-condition-variable))
(defvar *lem-host-state* :stopped
  "One of :STOPPED, :STARTING, :RUNNING or :FAILED.")
(defvar *lem-host-problem* nil
  "Why the host could not start, or what went wrong loading the init file.")
(defvar *lem-host-thread* nil)

(defun lem-host-init-file-wanted-p ()
  (and *lem-load-init-file* (not (equal (uiop:getenv "CL_AGENT_LEM_NO_INIT") "1"))))

(defun lem-host-load-init ()
  "What Lem's INIT does, less APPLY-ARGS (no splash screen, no files), and
keeping this process's PATH (Lem's macOS init hook rewrites it)."
  (let ((path (uiop:getenv "PATH")))
    (unwind-protect
         (progn
           (lem:run-hooks lem:*before-init-hook*)
           ;; Before the person's init file, which may want it after all.
           (setf lem/tabbar:*enable-tabbar-on-startup* *lem-tab-bar*)
           (when (lem-host-init-file-wanted-p)
             (handler-case
                 (progn
                   (lem-core::load-init-file)
                   (let ((own (merge-pathnames "cl-agent.lisp" (lem-core::lem-home))))
                     (when (probe-file own)
                       (let ((*package* (find-package :lem-user))) (load own)))))
               (error (condition)
                 (setf *lem-host-problem* (format nil "Your Lem init file failed: ~a" condition)))))
           (lem:run-hooks lem:*after-init-hook*))
      (when path (setf (uiop:getenv "PATH") path)))))

(defun lem-host-mark (state)
  (bordeaux-threads:with-lock-held (*lem-host-lock*)
    (setf *lem-host-state* state)
    (bordeaux-threads:condition-notify *lem-host-ready*)))

(defun lem-host-thread-body ()
  (unwind-protect
       (handler-case
           (lem-core::with-editor-stream ()
             (lem-core::with-timer-manager (make-instance 'lem-core::lem-timer-manager)
               (setf lem-core::*in-the-editor* t)
               (lem-core::setup)
               (lem-core::toplevel-command-loop
                (lambda ()
                  (lem-host-load-init)
                  (lem-host-mark :running)))
               (lem-core::teardown)))
         (error (condition)
           (setf *lem-host-problem* (format nil "Lem stopped: ~a" condition))))
    (setf lem-core::*in-the-editor* nil)
    (lem-host-mark (if (eq *lem-host-state* :starting) :failed :stopped))))

(defun lem-host-start (&key (timeout 30))
  "Start the editor thread unless it is running; return true once it is."
  (bordeaux-threads:with-lock-held (*lem-host-lock*)
    (when (member *lem-host-state* '(:stopped :failed))
      (setf *lem-host-state* :starting *lem-host-problem* nil)
      (handler-case
          (progn
            ;; lem-server's own setup: its frame-multiplexer tab bar does not
            ;; work with the web frontend.
            (lem-server::init)
            (lem-core::invoke-frontend
             (lambda (&optional initialize finalize)
               (declare (ignore initialize finalize))
               ;; Lem's editor thread is the agent's own, whoever needed it first.
               (setf *lem-host-thread*
                     (as-agent-itself
                       (bordeaux-threads:make-thread #'lem-host-thread-body :name "editor"))))
             :implementation (make-instance 'lem-host-display)))
        (error (condition)
          (setf *lem-host-state* :failed
                *lem-host-problem* (format nil "Lem could not start: ~a" condition)))))
    (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
          while (eq *lem-host-state* :starting)
          do (unless (bordeaux-threads:condition-wait
                      *lem-host-ready* *lem-host-lock*
                      :timeout (max 0.01 (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
               (when (>= (get-internal-real-time) deadline)
                 (setf *lem-host-problem* "Lem did not start in time.")
                 (return))))
    (eq *lem-host-state* :running)))

(defun lem-host-available-p ()
  "True when Lem is running here, starting it if need be."
  (or (eq *lem-host-state* :running)
      (and (not (eq *lem-host-state* :failed)) (lem-host-start))))

(defun lem-host-stop ()
  "Ask the editor thread to finish, as Lem's own exit does, and wait for it."
  (when (eq *lem-host-state* :running)
    (lem:send-event (lambda () (lem:exit-editor)))
    (let ((thread *lem-host-thread*))
      (when thread (ignore-errors (bordeaux-threads:join-thread thread))))))

(defun lem-host-status ()
  (list :state *lem-host-state* :problem *lem-host-problem*
        :lem-home (ignore-errors (namestring (lem-core::lem-home)))))

;;; --- calling into Lem ---

(define-condition lem-host-unavailable (error)
  ((reason :initarg :reason :reader lem-host-unavailable-reason))
  (:report (lambda (condition stream)
             (format stream "Lem is not available~@[: ~a~]" (lem-host-unavailable-reason condition)))))

;; Something other than the person typing is about to read or change a
;; buffer (the agent, the simple editor, a save): copilot.lisp's suggestion,
;; text shown in the buffer but not yet accepted, leaves first.
(defvar *lem-before-buffer-access* '()
  "Functions run on the editor thread before cl-agent itself reads or
changes a Lem buffer.")

(defun lem-before-buffer-access ()
  (dolist (function *lem-before-buffer-access*)
    (ignore-errors (funcall function))))

(defun lem-call (function &key (timeout *lem-call-timeout*))
  "Run FUNCTION on Lem's editor thread and return its value; its errors are
signalled here.  From the editor thread itself, just call it."
  (unless (lem-host-available-p)
    (error 'lem-host-unavailable :reason *lem-host-problem*))
  (when (eq (bordeaux-threads:current-thread) *lem-host-thread*)
    (return-from lem-call (funcall function)))
  (let ((lock (bordeaux-threads:make-lock "lem-call"))
        (done (bordeaux-threads:make-condition-variable))
        (finished nil) (value nil) (failure nil))
    (lem:send-event
     (lambda ()
       (handler-case (setf value (funcall function))
         (error (condition) (setf failure condition)))
       (bordeaux-threads:with-lock-held (lock)
         (setf finished t)
         (bordeaux-threads:condition-notify done))))
    (bordeaux-threads:with-lock-held (lock)
      (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
            until finished
            do (bordeaux-threads:condition-wait
                done lock :timeout (max 0.01 (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
               (when (and (not finished) (>= (get-internal-real-time) deadline))
                 (error "Lem did not answer within ~d seconds." timeout))))
    (if failure (error failure) value)))
