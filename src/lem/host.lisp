;;;; lem/host.lisp -- Lem's editor core, hosted in this image with no
;;;; display of its own (docs/lem-integration.md).
;;;;
;;;; LEM-HOST-INTERFACE is a Lem frontend that draws nothing: cl-agent's
;;;; own UI renders.  LEM-HOST-START runs Lem's editor thread the way
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

(defparameter *lem-call-timeout* 10
  "Seconds LEM-CALL waits for the editor thread.")

;;; --- the frontend: Lem's protocol, drawing nothing ---

(defclass lem-host-interface (lem:implementation)
  ((foreground :initform nil :accessor lem-host-foreground)
   (background :initform nil :accessor lem-host-background))
  (:default-initargs :name :cl-agent :redraw-after-modifying-floating-window nil))

(defstruct lem-host-view x y width height)

(defmethod lem-if:invoke ((interface lem-host-interface) function) (funcall function))
(defmethod lem-if:get-background-color ((interface lem-host-interface)) (lem:make-color 255 255 255))
(defmethod lem-if:get-foreground-color ((interface lem-host-interface)) (lem:make-color 0 0 0))
(defmethod lem-if:update-foreground ((interface lem-host-interface) color)
  (setf (lem-host-foreground interface) color))
(defmethod lem-if:update-background ((interface lem-host-interface) color)
  (setf (lem-host-background interface) color))
(defmethod lem-if:display-width ((interface lem-host-interface)) 200)
(defmethod lem-if:display-height ((interface lem-host-interface)) 60)
(defmethod lem-if:display-title ((interface lem-host-interface)) "cl-agent")
(defmethod lem-if:set-display-title ((interface lem-host-interface) title) title)
(defmethod lem-if:display-fullscreen-p ((interface lem-host-interface)) nil)
(defmethod lem-if:set-display-fullscreen-p ((interface lem-host-interface) fullscreen-p) fullscreen-p)
(defmethod lem-if:make-view ((interface lem-host-interface) window x y width height use-modeline)
  (declare (ignore window use-modeline))
  (make-lem-host-view :x x :y y :width width :height height))
(defmethod lem-if:delete-view ((interface lem-host-interface) view) view)
(defmethod lem-if:clear ((interface lem-host-interface) view) view)
(defmethod lem-if:set-view-size ((interface lem-host-interface) view width height)
  (setf (lem-host-view-width view) width (lem-host-view-height view) height))
(defmethod lem-if:set-view-pos ((interface lem-host-interface) view x y)
  (setf (lem-host-view-x view) x (lem-host-view-y view) y))
(defmethod lem-if:view-width ((interface lem-host-interface) view) (lem-host-view-width view))
(defmethod lem-if:view-height ((interface lem-host-interface) view) (lem-host-view-height view))
(defmethod lem-if:update-display ((interface lem-host-interface)) nil)
(defmethod lem-if:get-char-width ((interface lem-host-interface)) 1)
(defmethod lem-if:get-char-height ((interface lem-host-interface)) 1)
(defmethod lem-if:object-width ((interface lem-host-interface) object) (declare (ignore object)) 1)
(defmethod lem-if:object-height ((interface lem-host-interface) object) (declare (ignore object)) 1)
(defmethod lem-if:render-line ((interface lem-host-interface) view x y objects height)
  (declare (ignore view x y objects height)))
(defmethod lem-if:render-line-on-modeline ((interface lem-host-interface) view left right default-attribute height)
  (declare (ignore view left right default-attribute height)))
(defmethod lem-if:clear-to-end-of-window ((interface lem-host-interface) view y)
  (declare (ignore view y)))

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
          (lem-core::invoke-frontend
           (lambda (&optional initialize finalize)
             (declare (ignore initialize finalize))
             (setf *lem-host-thread*
                   (bordeaux-threads:make-thread #'lem-host-thread-body :name "editor")))
           :implementation (make-instance 'lem-host-interface))
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
