;;;; guard.lisp -- nothing the model does can take the agent down.
;;;;
;;;; The model runs code in this image -- eval-lisp, extensions it writes
;;;; (whose hooks then run on every turn), tools, Lisp in its replies -- and
;;;; any of it can be wrong.  The agent runs with SBCL's debugger disabled,
;;;; where a condition nobody handles, in any thread, ends the process.  So:
;;;;
;;;;   - WITH-AGENT-CODE marks code the model may have written (tool calls,
;;;;     hooks, extension loading, web routes, replies' Lisp); in it,
;;;;     exiting the image is refused.  So is exiting from any thread but
;;;;     the main one -- the agent's own shutdown happens there, and a thread
;;;;     the model starts is not WITH-AGENT-CODE.  The person still quits
;;;;     as ever: Ctrl-D, /exit.
;;;;   - WITH-TURN-GUARD runs a turn, a slash command or an input: anything
;;;;     serious that escapes it is reported (the frontend, :on-error) and
;;;;     the session carries on.  Ctrl-C (an interactive interrupt) is not
;;;;     caught: it still quits.
;;;;   - WITH-CONTAINED-EXITS stops the other way out: a non-local exit.
;;;;     (abort), (continue), invoking any restart, a THROW to an outer tag,
;;;;     a thread terminating another -- each unwinds past every handler,
;;;;     and from the main thread, out of the process.  Tool calls, hooks,
;;;;     extension loading, compiling the model's source and every turn run
;;;;     inside one: the exit is cancelled where it would leave, and reported.
;;;;     Only the person quitting (*EXIT-SANCTIONED*) passes.
;;;;   - INSTALL-SURVIVAL-HOOK (from MAIN) makes the process-wide debugger
;;;;     hook keep the process alive: an unhandled condition in a thread
;;;;     other than the main one aborts that thread's current work (its
;;;;     ABORT restart, else the thread) and is logged; the main thread's
;;;;     own loop is guarded by WITH-TURN-GUARD.
;;;;   - A real Ctrl-C (an interactive interrupt from SIGINT, which carries
;;;;     the signal's context) still quits; one the model's code signals
;;;;     itself is an ordinary error.

(in-package :cl-agent)

(defvar *agent-code-depth* 0
  "Above zero while code the model may have written runs.")

(defmacro with-agent-code (() &body body)
  `(call-with-agent-code (lambda () ,@body)))

;;; The threads running agent code now, for the memory guard (below).
(defvar *agent-threads* '()
  "(thread . last-interrupted) for each thread in agent code.")
(defvar *agent-threads-lock* (sb-thread:make-mutex :name "cl-agent agent threads"))

(declaim (ftype (function (function) *) call-with-agent-code))
(defun call-with-agent-code (thunk)
  (if (plusp *agent-code-depth*)
      (let ((*agent-code-depth* (1+ *agent-code-depth*)))
        (funcall thunk))
      (let ((*agent-code-depth* 1)
            (entry (cons sb-thread:*current-thread* 0)))
        (sb-thread:with-mutex (*agent-threads-lock*) (push entry *agent-threads*))
        (unwind-protect (funcall thunk)
          (sb-thread:with-mutex (*agent-threads-lock*)
            (setf *agent-threads* (delete entry *agent-threads* :test #'eq)))))))

(defmacro as-agent-itself (&body body)
  "Run BODY as the agent's own code, though agent code called it: for the
agent's long-lived service threads (Lem's editor, its display server, the
asset watcher...), which a tool or a route may be the first to need and
start.  A thread started in BODY is not counted as agent code."
  `(let ((*agent-code-depth* 0))
     ,@body))

(define-condition agent-exit-refused (error)
  ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (write-string "Exiting cl-agent from a tool, an extension or another thread is not allowed: the person quits it (Ctrl-D or /exit)." stream))))

(declaim (ftype (function () (values boolean &optional)) main-thread-p))
(defun main-thread-p ()
  (eq (sb-thread:main-thread) sb-thread:*current-thread*))

(defvar *exit-sanctioned* nil
  "True once the person is quitting: set (globally, never bound -- an exit
unwinds past any binding) when an exit is allowed, so WITH-CONTAINED-EXITS
lets the unwinding pass.")

(defun refuse-exit-in-agent-code (function &rest arguments)
  (cond ((or (plusp *agent-code-depth*) (not (main-thread-p)))
         (error 'agent-exit-refused))
        (t (setf *exit-sanctioned* t)
           (apply function arguments))))

(defun install-exit-guards ()
  (sb-ext:without-package-locks
    (dolist (name '(sb-ext:exit sb-ext:quit))
      (unless (sb-int:encapsulated-p name 'cl-agent-guard)
        (sb-int:encapsulate name 'cl-agent-guard #'refuse-exit-in-agent-code)))))

(install-exit-guards)

;;; Ending a thread the agent itself runs on -- the main one, a live
;;; session's, the web server's listener -- is refused: SB-THREAD:
;;; TERMINATE-THREAD (and BT:DESTROY-THREAD, which calls it) on one is an
;;; error.  The agent never does it; a thread the model starts might.

(declaim (ftype (function (t) (values boolean &optional)) protected-thread-p))
(defun protected-thread-p (thread)
  (or (eq thread (sb-thread:main-thread))
      (let ((name (ignore-errors (sb-thread:thread-name thread))))
        (and (stringp name)
             (or (search "cl-agent live session" name)
                 (search "hunchentoot-listener" name))
             t))))

(defun refuse-terminating-agent-threads (function thread &rest arguments)
  (if (and (protected-thread-p thread) (not *exit-sanctioned*))
      (error "~a runs cl-agent itself and cannot be terminated from code." (ignore-errors (sb-thread:thread-name thread)))
      (apply function thread arguments)))

(defun install-thread-guards ()
  (sb-ext:without-package-locks
    (unless (sb-int:encapsulated-p 'sb-thread:terminate-thread 'cl-agent-guard)
      (sb-int:encapsulate 'sb-thread:terminate-thread 'cl-agent-guard #'refuse-terminating-agent-threads))))

(install-thread-guards)

;;; --- conditions that escape ---

(declaim (ftype (function (t) (values boolean &optional)) interactive-interrupt-p))
(defun interactive-interrupt-p (condition)
  "True for a real Ctrl-C: an interactive interrupt raised by SIGINT, which
carries the signal's context.  One made with MAKE-CONDITION or ERROR has
none, and is treated as any other condition."
  (and (typep condition 'sb-sys:interactive-interrupt)
       (ignore-errors (slot-value condition 'sb-kernel::context))
       t))

(declaim (ftype (function (t) (values boolean &optional)) person-interrupt-p))
(defun person-interrupt-p (condition)
  "For a guard's handler: true for a real Ctrl-C, which the guard lets
through -- and the person is quitting, so the unwinding it starts (the
command line's own handler, say, catching it to exit) passes every
WITH-CONTAINED-EXITS on its way out."
  (when (interactive-interrupt-p condition)
    (setf *exit-sanctioned* t)
    t))

;;; --- non-local exits ---

(define-condition agent-escape (error)
  ((where :initarg :where :initform "Agent code" :reader agent-escape-where))
  (:report (lambda (condition stream)
             (format stream "~a tried to leave by a non-local exit -- (abort), (continue), a restart, a THROW past its caller or a thread's termination -- and was stopped there.  Return a value, or signal an error, instead."
                     (agent-escape-where condition)))))

(defmacro with-contained-exits ((&key on-escape) &body body)
  "Run BODY and return its values.  If BODY leaves by a non-local exit
that crosses this form -- (abort), (continue), INVOKE-RESTART, a THROW to
an outer tag, a thread's termination -- the exit is cancelled here and
ON-ESCAPE is evaluated and returned instead.  The person quitting
(*EXIT-SANCTIONED*) is let through.

Exits inside BODY are BODY's own business; so a handler that should
take a condition out of BODY must be established inside this form."
  (let ((normal (gensym "NORMAL")) (block (gensym "CONTAINED")))
    `(let ((,normal nil))
       (block ,block
         (unwind-protect
              (return-from ,block
                (multiple-value-prog1 (progn ,@body) (setf ,normal t)))
           ;; A RETURN-FROM in a cleanup supersedes the unwinding under way.
           (unless (or ,normal *exit-sanctioned*)
             (return-from ,block ,on-escape)))))))

(declaim (ftype (function (condition) (values string &optional)) describe-escaped-condition))
(defun describe-escaped-condition (condition)
  (format nil "~a: ~a" (type-of condition)
          (handler-case (let ((text (princ-to-string condition)))
                          (subseq text 0 (min 600 (length text))))
            (serious-condition () "(its report failed)"))))

(declaim (ftype (function (condition t) (values t &optional)) note-escaped-condition))
(defun note-escaped-condition (condition where)
  "Log CONDITION, which escaped WHERE, and tell :on-error."
  (ignore-errors (format *error-output* "~&[cl-agent] ~a: ~a~%" where (describe-escaped-condition condition)))
  (ignore-errors (when (fboundp 'run-hook) (funcall 'run-hook :on-error condition))))

(declaim (ftype (function (function t) *) call-as-contained-agent-code))
(defun call-as-contained-agent-code (thunk where)
  "Call THUNK as agent code and return its values.  What it signals that
is serious (but a real Ctrl-C) is signalled again here, once THUNK has been
left -- so a caller's HANDLER-CASE sees the original condition; a
non-local exit out of THUNK is signalled as an AGENT-ESCAPE from WHERE."
  (let* ((failure nil)
         (values (with-contained-exits (:on-escape (progn (setf failure (make-condition 'agent-escape :where where))
                                                          nil))
                   (block run
                     (handler-bind ((serious-condition
                                      (lambda (condition)
                                        (unless (person-interrupt-p condition)
                                          (setf failure condition)
                                          (return-from run nil)))))
                       (multiple-value-list (with-agent-code () (funcall thunk))))))))
    (when failure (error failure))
    (values-list values)))

(defmacro contained-agent-code ((&key (where "Agent code")) &body body)
  "BODY as CALL-AS-CONTAINED-AGENT-CODE runs it."
  `(call-as-contained-agent-code (lambda () ,@body) ,where))

(declaim (ftype (function (condition t t) (values t &optional)) report-escaped-condition))
(defun report-escaped-condition (condition where frontend)
  (note-escaped-condition condition where)
  (when frontend
    (ignore-errors
     (ui-error frontend
               (make-condition 'simple-error
                               :format-control "~a failed, and was stopped: ~a"
                               :format-arguments (list where (describe-escaped-condition condition)))))))

(defmacro with-turn-guard ((&key frontend (where "the turn")) &body body)
  "Run BODY; a serious condition escaping it (but Ctrl-C), or a non-local
exit leaving it, is reported -- on FRONTEND too, when given -- and BODY's
value is then NIL."
  (let ((block (gensym "GUARDED")) (condition (gensym "CONDITION"))
        (place (gensym "WHERE")) (ui (gensym "FRONTEND")))
    `(let ((,place ,where) (,ui ,frontend))
       (declare (ignorable ,ui))
       (with-contained-exits (:on-escape (progn (report-escaped-condition
                                                 (make-condition 'agent-escape :where ,place) ,place ,ui)
                                                nil))
         (block ,block
           (handler-bind ((serious-condition
                            (lambda (,condition)
                              (unless (person-interrupt-p ,condition)
                                (report-escaped-condition ,condition ,place ,ui)
                                (return-from ,block nil)))))
             ,@body))))))

;;; --- memory ---
;;;
;;; An unhandled condition is not the only way out: when live data fills
;;; about half the heap, SBCL's copying collector itself runs out of room
;;; ("Heap exhausted, game over") -- no handler runs, the process ends.  So
;;; after each collection, when the heap is more than *AGENT-MEMORY-LIMIT*
;;; full, every thread running agent code -- tool calls, hooks, threads the
;;; model started -- gets an AGENT-MEMORY-EXHAUSTED (a STORAGE-CONDITION):
;;; it unwinds, and what it was building is garbage again.

(defvar *agent-memory-limit* 0.5
  "Fraction of the heap past which agent code is stopped.")

(define-condition agent-memory-exhausted (storage-condition)
  ((used :initarg :used :reader agent-memory-used)
   (size :initarg :size :reader agent-memory-size))
  (:report (lambda (condition stream)
             (format stream "Stopped: the agent's heap was ~d% full (~:d MB of ~:d MB) while this code ran, and it would have ended the process.  Free what it holds (a global variable, a cache), or work in smaller pieces."
                     (round (* 100 (agent-memory-used condition)) (agent-memory-size condition))
                     (round (agent-memory-used condition) 1000000) (round (agent-memory-size condition) 1000000)))))

(defun signal-agent-memory-exhausted (used size)
  ;; Runs in the interrupted thread: only code still in agent code is stopped.
  (when (plusp *agent-code-depth*)
    (error 'agent-memory-exhausted :used used :size size)))

(defvar *memory-guard-wakeup* (sb-thread:make-semaphore :name "cl-agent memory guard"))
(defvar *memory-guard-thread* nil)

(declaim (ftype (function () (values boolean &optional)) heap-over-limit-p))
(defun heap-over-limit-p ()
  (> (sb-kernel:dynamic-usage) (* *agent-memory-limit* (sb-ext:dynamic-space-size))))

(declaim (ftype (function () (values t &optional)) check-agent-memory))
(defun check-agent-memory ()
  "Stop the agent code running now when the heap's live data is over its
limit.  The heap counts garbage not yet collected, so a full collection
decides first: only what survives it counts."
  (when (heap-over-limit-p)
    (sb-ext:gc :full t)
    (when (heap-over-limit-p)
      (let ((used (sb-kernel:dynamic-usage)) (size (sb-ext:dynamic-space-size))
            (now (get-internal-real-time)))
        (dolist (entry (sb-thread:with-mutex (*agent-threads-lock*) (copy-list *agent-threads*)))
          ;; Once a second each, at most: unwinding takes a moment.
          (when (> (- now (cdr entry)) internal-time-units-per-second)
            (setf (cdr entry) now)
            (ignore-errors
             (sb-thread:interrupt-thread (car entry)
                                         (lambda () (signal-agent-memory-exhausted used size))))))))))

(defun wake-memory-guard ()
  "The after-GC hook: cheap, and safe in whatever thread runs it -- the
guard's own thread does the work."
  (when (heap-over-limit-p)
    (sb-thread:signal-semaphore *memory-guard-wakeup*)))

(defun memory-guard-loop ()
  (loop
    (sb-thread:wait-on-semaphore *memory-guard-wakeup*)
    (ignore-errors (check-agent-memory))
    ;; Wakeups that came meanwhile -- the check's own collection among
    ;; them -- are this check; and at most one check a second.
    (loop while (sb-thread:try-semaphore *memory-guard-wakeup*))
    (sleep 1)))

(defun install-memory-guard ()
  "Hook the guard to the collector, and start its thread (lazily: an image
being saved must have no other threads -- see STOP-MEMORY-GUARD)."
  (pushnew 'wake-memory-guard sb-ext:*after-gc-hooks*)
  (unless (and *memory-guard-thread* (sb-thread:thread-alive-p *memory-guard-thread*))
    (setf *memory-guard-thread*
          (let ((*agent-code-depth* 0))
            (sb-thread:make-thread #'memory-guard-loop :name "cl-agent memory guard")))))

(defun stop-memory-guard ()
  (let ((thread *memory-guard-thread*))
    (setf *memory-guard-thread* nil)
    (when (and thread (sb-thread:thread-alive-p thread))
      (sb-thread:terminate-thread thread)
      (ignore-errors (sb-thread:join-thread thread :default nil :timeout 5)))))

(pushnew 'stop-memory-guard sb-ext:*save-hooks*)

;;; A thread started from agent code runs agent code too: it is counted
;;; for the memory guard, and cannot exit the image.  (The agent's own
;;; threads, started from its own code, bind *AGENT-CODE-DEPTH* to 0.)

(defun mark-agent-threads (function thread-function &rest arguments)
  (if (plusp *agent-code-depth*)
      (apply function (lambda (&rest thread-arguments)
                        (with-agent-code () (apply thread-function thread-arguments)))
             arguments)
      (apply function thread-function arguments)))

(defun install-thread-marking ()
  (sb-ext:without-package-locks
    (unless (sb-int:encapsulated-p 'sb-thread:make-thread 'cl-agent-guard)
      (sb-int:encapsulate 'sb-thread:make-thread 'cl-agent-guard #'mark-agent-threads))))

(pushnew 'wake-memory-guard sb-ext:*after-gc-hooks*)
(install-thread-marking)

(defvar *previous-debugger-hook* nil)

(defun survival-debugger-hook (condition hook)
  "The process-wide debugger hook (INSTALL-SURVIVAL-HOOK)."
  (if (or (interactive-interrupt-p condition)
          (and (main-thread-p) (not (find-restart 'return-to-prompt condition))))
      ;; Ctrl-C, or the main thread has let something through outside its
      ;; loop: what SBCL would do -- the person's quit, not the model's.
      (progn
        (setf *exit-sanctioned* t)
        (let ((*agent-code-depth* 0))
          (if *previous-debugger-hook*
              (funcall *previous-debugger-hook* condition hook)
              (sb-debug::debugger-disabled-hook condition hook))))
      (progn
        (note-escaped-condition condition (format nil "thread ~s" (ignore-errors (sb-thread:thread-name sb-thread:*current-thread*))))
        (let ((abort (or (find-restart 'return-to-prompt condition) (find-restart 'abort condition))))
          (if abort
              (invoke-restart abort)
              (sb-thread:abort-thread))))))

(defvar *survival-hook-installed* nil)

(defun install-survival-hook ()
  "Make an unhandled condition in a thread other than the main one end
only that thread's work, not the process."
  (unless (eq sb-ext:*invoke-debugger-hook* 'survival-debugger-hook)
    (setf *previous-debugger-hook* sb-ext:*invoke-debugger-hook*
          sb-ext:*invoke-debugger-hook* 'survival-debugger-hook))
  (install-memory-guard)
  (setf *survival-hook-installed* t))

(declaim (ftype (function () (values t &optional)) reassert-guards))
(defun reassert-guards ()
  "Put back any guard the model's code took away -- the global debugger
hook, the exit and thread guards -- after a tool call, a hook, a step of
the session loop.  Cheap: each is a check."
  (ignore-errors
   (when (and *survival-hook-installed*
              (not (eq (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) 'survival-debugger-hook)))
     (setf (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) 'survival-debugger-hook)))
  (ignore-errors (install-exit-guards))
  (ignore-errors (install-thread-guards))
  (ignore-errors (install-memory-guard))
  (ignore-errors (install-thread-marking)))
