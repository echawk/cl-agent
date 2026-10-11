;;;; ui/web/lisp-repl.lisp -- the web UI's Lisp tab: a SLY-style REPL on
;;;; the agent's own image and a scratch buffer shared with the agent.
;;;; There is one REPL per process, shared by every open page.
;;;;
;;;;   Evaluation     LISP-REPL-START runs TEXT's forms on a fresh thread.
;;;;                  Output streams to pages as "lisp-output" events; the
;;;;                  entry itself (input, values, state) as "lisp-entry".
;;;;   Debugger       an unhandled condition, BREAK, or an interrupt parks
;;;;                  that thread in LISP-REPL-DEBUGGER, which publishes the
;;;;                  condition, backtrace and restarts, then waits for a
;;;;                  page to pick one (LISP-REPL-CHOOSE).
;;;;   Presentations  each printed value gets an id that pages click to
;;;;                  inspect (lisp-introspect.lisp), and that Lisp code can
;;;;                  get back with (LISP-REPL-OBJECT ID).
;;;;   Scratch        repl/scratch.lisp in the config directory, versioned
;;;;                  so the page and the agent (tools/lisp-scratch-tool)
;;;;                  never silently overwrite each other.
;;;;
;;;; HTTP routes: lisp-routes.lisp.  The client: static/lisp.js.

(in-package :cl-agent)

(defparameter *lisp-repl-entry-limit* 300 "Transcript entries kept.")
(defparameter *lisp-repl-object-limit* 5000 "Presented objects kept for inspection.")
(defparameter *lisp-repl-output-limit* 200000 "Characters of output kept per entry.")
(defparameter *lisp-repl-value-limit* 20000 "Characters of a printed value shown.")
(defparameter *lisp-repl-backtrace-limit* 60 "Backtrace frames shown in the debugger.")

(define-condition lisp-repl-busy (error) ()
  (:report "The Lisp REPL is busy; interrupt it or pick a debugger restart first."))

(define-condition lisp-repl-interrupt (condition) ()
  (:report "Interrupted by the user."))

(defstruct (lisp-entry (:constructor %make-lisp-entry))
  id source mode input package
  (state :running)                       ; :running :debugger :done :aborted
  (output (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
  values                                 ; ((:text :id :type) ...) of the last form
  notes                                  ; ((:severity :message) ...), oldest first
  debugger                               ; plist while (or after) in the debugger
  (time (unix-time-now))
  elapsed)

(defstruct (lisp-repl (:constructor make-lisp-repl ()))
  (lock (bt:make-lock "cl-agent-lisp-repl"))
  (cv (bt:make-condition-variable))
  (package (find-package :cl-agent))
  (entries nil)                          ; newest first
  (next-id 0)
  (objects (make-hash-table))
  (next-object 0)
  (history nil)                          ; plist of * ** *** + ++ +++ / // ///
  (thread nil)
  (current nil)                          ; the entry being evaluated
  (choice nil))                          ; a page's debugger choice, waiting to be taken

(defvar *lisp-repl* (make-lisp-repl))

(defvar *lisp-repl-abort-restart* nil
  "The evaluation's own ABORT restart; restarts outside it (the thread's)
are not offered in the debugger.")

(defun lisp-repl-publish (type payload)
  (when *web-frontends* (web-ui-broadcast type payload)))

;;; --- packages ---

(defun package-display-name (package)
  "PACKAGE's name as a prompt shows it: its name, or for a long one
(COMMON-LISP-USER) its shortest nickname (CL-USER)."
  (let ((name (package-name package)))
    (if (<= (length name) 12)
        name
        (reduce (lambda (a b) (if (< (length b) (length a)) b a))
                (package-nicknames package) :initial-value name))))

(defun clip-text (text limit)
  (if (> (length text) limit) (concatenate 'string (subseq text 0 limit) " …") text))

(defun lisp-repl-find-package (designator)
  "The package DESIGNATOR names, as written in source: cl-agent, :cl-agent,
#:cl-agent or \"CL-AGENT\".  NIL when there is none."
  (when (and (stringp designator) (plusp (length designator)))
    (let ((name (string-trim "\"' " (string-left-trim "#:" designator))))
      (or (find-package name) (find-package (string-upcase name))))))

;;; --- presentations ---

(defun lisp-repl-present (object &optional (repl *lisp-repl*))
  "Remember OBJECT for inspection and return its presentation id."
  (bt:with-lock-held ((lisp-repl-lock repl))
    (let ((id (incf (lisp-repl-next-object repl)))
          (objects (lisp-repl-objects repl)))
      (setf (gethash id objects) object)
      (remhash (- id *lisp-repl-object-limit*) objects)
      id)))

(defun lisp-repl-object (id &optional (repl *lisp-repl*))
  "The object the Lisp tab printed with presentation ID: alt-click a value
to put (cl-agent::lisp-repl-object ID) in the REPL input."
  (multiple-value-bind (object found)
      (bt:with-lock-held ((lisp-repl-lock repl)) (gethash id (lisp-repl-objects repl)))
    (if found object (error "The REPL no longer remembers object ~a." id))))

(defun lisp-repl-print (object &key (limit *lisp-repl-value-limit*) (pretty t))
  "OBJECT as the REPL prints it, cut at LIMIT characters; never signals."
  (let ((text (handler-case
                  (let ((*print-circle* t) (*print-pretty* pretty) (*print-right-margin* 100)
                        (*print-readably* nil))
                    (prin1-to-string object))
                (error (condition)
                  (format nil "#<error printing a ~a: ~a>"
                          (ignore-errors (type-of object)) (ignore-errors (princ-to-string condition)))))))
    (if (> (length text) limit) (concatenate 'string (subseq text 0 limit) " …") text)))

(defun lisp-repl-value-plist (object)
  (list :text (lisp-repl-print object) :id (lisp-repl-present object)
        :type (lisp-repl-print (type-of object) :limit 200 :pretty nil)))

;;; --- entries as JSON ---

(defun lisp-entry-json (entry)
  (jobj "id" (lisp-entry-id entry)
        "source" (lisp-entry-source entry)
        "mode" (lisp-entry-mode entry)
        "input" (lisp-entry-input entry)
        "package" (lisp-entry-package entry)
        "state" (string-downcase (symbol-name (lisp-entry-state entry)))
        "output" (copy-seq (lisp-entry-output entry))
        "values" (jarray (mapcar (lambda (value)
                                   (jobj "text" (getf value :text) "id" (getf value :id)
                                         "type" (getf value :type)))
                                 (lisp-entry-values entry)))
        "notes" (jarray (mapcar (lambda (note)
                                  (jobj "severity" (getf note :severity) "message" (getf note :message)))
                                (lisp-entry-notes entry)))
        "debugger" (let ((debugger (lisp-entry-debugger entry)))
                     (if debugger
                         (jobj "condition" (getf debugger :condition)
                               "type" (getf debugger :type)
                               "id" (getf debugger :id)
                               "restarts" (jarray (loop for (name report) in (getf debugger :restarts)
                                                        for index from 0
                                                        collect (jobj "index" index "name" name "report" report)))
                               "backtrace" (jarray (getf debugger :backtrace))
                               "note" (json-or-null (getf debugger :note)))
                         :null))
        "time" (lisp-entry-time entry)
        "elapsed" (json-or-null (lisp-entry-elapsed entry))))

(defun lisp-repl-publish-entry (entry &optional (repl *lisp-repl*))
  (lisp-repl-publish "lisp-entry"
                     (jobj "entry" (lisp-entry-json entry)
                           "package" (package-display-name (lisp-repl-package repl))
                           "busy" (and (lisp-repl-current repl) t))))

(defun lisp-repl-state-json (&optional (repl *lisp-repl*))
  (multiple-value-bind (text version) (lisp-scratch-contents)
    (jobj "package" (package-display-name (lisp-repl-package repl))
          "busy" (and (lisp-repl-current repl) t)
          "entries" (jarray (mapcar #'lisp-entry-json
                                    (reverse (subseq (lisp-repl-entries repl)
                                                     0 (min 150 (length (lisp-repl-entries repl)))))))
          "scratch" (jobj "text" text "version" version
                          "path" (namestring (lisp-scratch-pathname))))))

;;; --- output: a stream that streams to the page ---

(defclass lisp-repl-output (sb-gray:fundamental-character-output-stream)
  ((entry :initarg :entry :reader lisp-repl-output-entry)
   (pending :initform (make-string-output-stream) :reader lisp-repl-output-pending)
   (pending-count :initform 0 :accessor lisp-repl-output-pending-count)
   (column :initform 0 :accessor lisp-repl-output-column)
   (flushed-at :initform 0 :accessor lisp-repl-output-flushed-at))
  (:documentation "Collects what an evaluation prints into its entry and
publishes it to pages in chunks (each line, at most ~20 times a second)."))

(defun lisp-repl-flush-output (stream)
  (let ((text (get-output-stream-string (lisp-repl-output-pending stream)))
        (entry (lisp-repl-output-entry stream)))
    (setf (lisp-repl-output-pending-count stream) 0
          (lisp-repl-output-flushed-at stream) (get-internal-real-time))
    (when (plusp (length text))
      (let* ((room (max 0 (- *lisp-repl-output-limit* (length (lisp-entry-output entry)))))
             (kept (if (> (length text) room)
                       (concatenate 'string (subseq text 0 room)
                                    (if (plusp room) (format nil "~%;; … output truncated~%") ""))
                       text)))
        (when (plusp (length kept))
          (format (lisp-entry-output entry) "~a" kept)
          (lisp-repl-publish "lisp-output" (jobj "id" (lisp-entry-id entry) "text" kept)))))))

(defmethod sb-gray:stream-write-char ((stream lisp-repl-output) char)
  (write-char char (lisp-repl-output-pending stream))
  (incf (lisp-repl-output-pending-count stream))
  (setf (lisp-repl-output-column stream)
        (if (char= char #\Newline) 0 (1+ (lisp-repl-output-column stream))))
  (when (or (> (lisp-repl-output-pending-count stream) 8192)
            (and (char= char #\Newline)
                 (> (- (get-internal-real-time) (lisp-repl-output-flushed-at stream))
                    (floor internal-time-units-per-second 20))))
    (lisp-repl-flush-output stream))
  char)

(defmethod sb-gray:stream-line-column ((stream lisp-repl-output))
  (lisp-repl-output-column stream))

(defmethod sb-gray:stream-force-output ((stream lisp-repl-output))
  (lisp-repl-flush-output stream)
  nil)

(defmethod sb-gray:stream-finish-output ((stream lisp-repl-output))
  (lisp-repl-flush-output stream)
  nil)

;;; --- the debugger ---

(defun lisp-repl-backtrace ()
  "The calling thread's backtrace as frame strings, from the frame that
signalled down to the REPL's own evaluation loop."
  (let* ((text (with-output-to-string (s)
                 (let ((*print-pretty* nil) (*print-length* 8) (*print-level* 4) (*print-circle* t))
                   (ignore-errors (sb-debug:print-backtrace :count 200 :stream s)))))
         (frames (loop for line in (uiop:split-string text :separator '(#\Newline))
                       for trimmed = (string-trim " " line)
                       when (and (plusp (length trimmed))
                                 (not (uiop:string-prefix-p "Backtrace for" trimmed)))
                         collect (let ((colon (search ": " trimmed)))
                                   (if (and colon (every #'digit-char-p (subseq trimmed 0 colon)))
                                       (subseq trimmed (+ colon 2))
                                       trimmed))))
         ;; Drop the debugger's own frames above the signal...
         (start (let ((hook (position-if (lambda (frame)
                                           (or (search "INVOKE-DEBUGGER" frame)
                                               (search "LISP-REPL-DEBUGGER" frame)))
                                         frames :from-end t)))
                  (if hook (1+ hook) 0)))
         ;; ...and the REPL machinery below the user's form.
         (end (or (position-if (lambda (frame) (search "LISP-REPL-EVAL-FORMS" frame)) frames :start start)
                  (length frames))))
    (subseq frames start (min end (+ start *lisp-repl-backtrace-limit*)))))

(defun lisp-repl-take-choice (repl)
  "Block until a page picks a debugger choice, and return it."
  (bt:with-lock-held ((lisp-repl-lock repl))
    (loop until (lisp-repl-choice repl)
          do (bt:condition-wait (lisp-repl-cv repl) (lisp-repl-lock repl) :timeout 5))
    (shiftf (lisp-repl-choice repl) nil)))

(defun lisp-repl-choose (choice &key input (repl *lisp-repl*))
  "Answer the debugger: CHOICE is a restart index or :ABORT.  INPUT is text
the restart's interactive prompt reads (e.g. the value for USE-VALUE)."
  (bt:with-lock-held ((lisp-repl-lock repl))
    (let ((entry (lisp-repl-current repl)))
      (unless (and entry (eq (lisp-entry-state entry) :debugger))
        (error "The Lisp REPL is not in the debugger."))
      (setf (lisp-repl-choice repl) (list choice input)
            (lisp-entry-state entry) :running)
      (bt:condition-notify (lisp-repl-cv repl))
      t)))

(defun lisp-repl-debugger (repl entry condition)
  "The REPL's debugger: publish CONDITION with its restarts and backtrace,
then invoke whichever restart a page picks.  Never returns normally."
  (let* ((all (compute-restarts condition))
         (restarts (subseq all 0 (let ((own (position *lisp-repl-abort-restart* all)))
                                   (if own (1+ own) (length all)))))
         (*print-circle* t))
    (setf (lisp-entry-debugger entry)
          (list :condition (clip-text (or (ignore-errors (princ-to-string condition))
                                          "(the condition's report failed)")
                                      4000)
                :type (lisp-repl-print (type-of condition) :limit 200 :pretty nil)
                :id (lisp-repl-present condition repl)
                :restarts (mapcar (lambda (restart)
                                    (list (string-upcase (string (or (restart-name restart) "")))
                                          (or (ignore-errors (princ-to-string restart)) "")))
                                  restarts)
                :backtrace (lisp-repl-backtrace))
          (lisp-entry-state entry) :debugger)
    (finish-output *standard-output*)
    (lisp-repl-publish-entry entry repl)
    (loop
      (destructuring-bind (choice input) (lisp-repl-take-choice repl)
        (if (eq choice :abort)
            (throw 'lisp-repl-abort :aborted)
            (let ((restart (and (integerp choice) (nth choice restarts))))
              (setf (lisp-entry-state entry) :running
                    (getf (lisp-entry-debugger entry) :note) nil)
              (lisp-repl-publish-entry entry repl)
              (handler-case
                  (let ((*query-io* (make-two-way-stream (make-string-input-stream (or input ""))
                                                         (make-broadcast-stream))))
                    (if restart
                        (invoke-restart-interactively restart)
                        (error "There is no restart number ~a." choice)))
                (error (problem)
                  (setf (lisp-entry-state entry) :debugger
                        (getf (lisp-entry-debugger entry) :note)
                        (format nil "~a~@[ (this restart reads a value: type it in the box)~]"
                                (clip-text (or (ignore-errors (princ-to-string problem)) "") 1000)
                                (typep problem 'end-of-file)))
                  (lisp-repl-publish-entry entry repl)))))))))

;;; --- evaluation ---

(defparameter *lisp-repl-history-variables* '(* ** *** + ++ +++ / // ///))

(defun lisp-repl-note (entry condition)
  (let ((severity (typecase condition
                    (style-warning "style-warning")
                    (warning "warning")
                    (t "note"))))
    (setf (lisp-entry-notes entry)
          (append (lisp-entry-notes entry)
                  (list (list :severity severity
                              :message (clip-text (or (ignore-errors (princ-to-string condition)) "") 2000)))))))

(defun lisp-repl-eval-forms (entry text mode)
  "Evaluate TEXT's forms in order (compiling each first in \"compile\" MODE),
keeping the REPL variables up to date; the last form's values are ENTRY's."
  (with-input-from-string (in text)
    (loop with eof = '#:eof
          for form = (read in nil eof)
          until (eq form eof)
          do (setf - form)
             (let ((values (loop (restart-case
                                     (return (multiple-value-list
                                              (if (equal mode "compile")
                                                  (funcall (compile nil `(lambda () ,form)))
                                                  (eval form))))
                                   (retry ()
                                     :report "Evaluate the form again."
                                     nil)))))
               (shiftf +++ ++ + -)
               (shiftf /// // / values)
               (shiftf *** ** * (first values))
               (setf (lisp-entry-values entry) (mapcar #'lisp-repl-value-plist values))))))

(defun lisp-repl-compile-file (entry pathname)
  "COMPILE-FILE and LOAD PATHNAME (the scratch buffer); ENTRY gets one value
summarizing the compilation, like SLY's C-c C-k."
  (let ((fasl (uiop:tmpize-pathname (merge-pathnames "cl-agent-scratch.fasl" (uiop:temporary-directory)))))
    (unwind-protect
         (multiple-value-bind (output warnings-p failure-p)
             (compile-file pathname :output-file fasl)
           (when (and output (not failure-p)) (load output))
           (setf (lisp-entry-values entry)
                 (list (lisp-repl-value-plist
                        (format nil "~:[Compiled and loaded~;Compilation failed~] ~a~:[~; (with warnings)~]"
                                failure-p (file-namestring pathname) warnings-p)))))
      (ignore-errors (delete-file fasl)))))

;; NB: when *, + and / appear below as variables they are CL's REPL variables.
(defun lisp-repl-run (repl entry text mode package keep-package-p)
  "The body of an evaluation thread: evaluate, then record the outcome."
  (let ((out (make-instance 'lisp-repl-output :entry entry))
        (started (get-internal-real-time))
        (outcome nil))
    (progv *lisp-repl-history-variables*
        (let ((history (lisp-repl-history repl)))
          (mapcar (lambda (name) (getf history name)) *lisp-repl-history-variables*))
      (let ((- nil)
            (*lisp-repl-abort-restart* nil)
            (*package* package)
            (*standard-output* out) (*error-output* out) (*trace-output* out)
            (*standard-input* (make-string-input-stream ""))
            (*query-io* (make-two-way-stream (make-string-input-stream "") out))
            (*debug-io* (make-two-way-stream (make-string-input-stream "") out))
            (*debugger-hook* nil)
            (sb-ext:*invoke-debugger-hook*
              (lambda (condition hook)
                (declare (ignore hook))
                (lisp-repl-debugger repl entry condition))))
        (unwind-protect
             (setf outcome
                   (catch 'lisp-repl-abort
                     (with-simple-restart (abort "Return to the Lisp REPL.")
                       (setf *lisp-repl-abort-restart* (find-restart 'abort))
                       ;; Warnings become the entry's notes; only COMPILE-FILE
                       ;; keeps printing its own report as well.
                       (handler-bind ((warning (lambda (condition)
                                                 (lisp-repl-note entry condition)
                                                 (let ((muffle (find-restart 'muffle-warning condition)))
                                                   (when (and muffle (not (equal mode "compile-file")))
                                                     (invoke-restart muffle))))))
                         (if (equal mode "compile-file")
                             (lisp-repl-compile-file entry (lisp-scratch-pathname))
                             (lisp-repl-eval-forms entry text mode)))
                       :done)))
          (ignore-errors (finish-output out))
          (bt:with-lock-held ((lisp-repl-lock repl))
            (setf (lisp-repl-history repl)
                  (loop for name in *lisp-repl-history-variables*
                        collect name collect (symbol-value name)))
            (when (and keep-package-p (packagep *package*) (package-name *package*))
              (setf (lisp-repl-package repl) *package*))
            (setf (lisp-entry-state entry) (if (eq outcome :done) :done :aborted)
                  (lisp-entry-elapsed entry) (float (/ (- (get-internal-real-time) started)
                                                       internal-time-units-per-second))
                  (lisp-repl-current repl) nil
                  (lisp-repl-thread repl) nil
                  (lisp-repl-choice repl) nil))
          (lisp-repl-publish-entry entry repl))))
    outcome))

(defun lisp-repl-start (text &key (source "repl") (mode "eval") package (repl *lisp-repl*))
  "Begin evaluating TEXT on a new thread and return its entry at once.
MODE is \"eval\", \"compile\" (compile each form first, collecting its
warnings, like SLY's C-c C-c) or \"compile-file\" (compile and load the
scratch buffer; TEXT is only shown).  With PACKAGE (a designator string)
the forms are read there and the REPL's own package is left alone;
otherwise an IN-PACKAGE in TEXT moves the REPL, as at a prompt.  Signals
LISP-REPL-BUSY while another evaluation is running."
  (let ((explicit (and package (or (lisp-repl-find-package package)
                                   (error "There is no package named ~a." package))))
        (config *config-directory*)
        (session *current-session*)
        entry chosen)
    (bt:with-lock-held ((lisp-repl-lock repl))
      (when (lisp-repl-current repl) (error 'lisp-repl-busy))
      (unless (package-name (lisp-repl-package repl))   ; deleted under us
        (setf (lisp-repl-package repl) (find-package :cl-agent)))
      (setf chosen (or explicit (lisp-repl-package repl))
            entry (%make-lisp-entry :id (incf (lisp-repl-next-id repl)) :source source :mode mode
                                    :input text :package (package-display-name chosen)))
      (push entry (lisp-repl-entries repl))
      (when (> (length (lisp-repl-entries repl)) *lisp-repl-entry-limit*)
        (setf (lisp-repl-entries repl) (subseq (lisp-repl-entries repl) 0 *lisp-repl-entry-limit*)))
      (setf (lisp-repl-current repl) entry
            (lisp-repl-choice repl) nil))
    (lisp-repl-publish-entry entry repl)
    (bt:make-thread (lambda ()
                      (let ((*config-directory* config) (*current-session* session))
                        (bt:with-lock-held ((lisp-repl-lock repl))
                          (setf (lisp-repl-thread repl) (bt:current-thread)))
                        (lisp-repl-run repl entry text mode chosen (null explicit))))
                    :name "cl-agent Lisp REPL")
    entry))

(defun lisp-repl-busy-p (&optional (repl *lisp-repl*))
  (and (lisp-repl-current repl) t))

(defun lisp-repl-interrupt (&optional (repl *lisp-repl*))
  "Break into the running evaluation: it enters the debugger with a
CONTINUE restart (SLY's C-c C-c).  Already in the debugger, abort instead.
Returns :INTERRUPTED, :ABORTED, or NIL when nothing is running."
  (multiple-value-bind (thread entry)
      (bt:with-lock-held ((lisp-repl-lock repl))
        (values (lisp-repl-thread repl) (lisp-repl-current repl)))
    (cond ((null entry) nil)
          ((eq (lisp-entry-state entry) :debugger)
           (lisp-repl-choose :abort :repl repl)
           :aborted)
          ((and thread (bt:thread-alive-p thread))
           (sb-thread:interrupt-thread
            thread
            (lambda ()
              (sb-sys:with-interrupts
                (with-simple-restart (continue "Continue the interrupted evaluation.")
                  (invoke-debugger (make-condition 'lisp-repl-interrupt))))))
           :interrupted))))

(defun lisp-repl-wait (entry &key (timeout 10) (repl *lisp-repl*))
  "Wait until ENTRY finishes or enters the debugger (for tests and tools);
returns its state."
  (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
        for state = (bt:with-lock-held ((lisp-repl-lock repl)) (lisp-entry-state entry))
        until (or (member state '(:done :aborted :debugger)) (> (get-internal-real-time) deadline))
        do (sleep 0.01)
        finally (return state)))

(defun lisp-repl-clear (&optional (repl *lisp-repl*))
  "Forget the transcript (an evaluation still running is kept)."
  (bt:with-lock-held ((lisp-repl-lock repl))
    (setf (lisp-repl-entries repl)
          (remove-if-not (lambda (entry) (eq entry (lisp-repl-current repl))) (lisp-repl-entries repl))))
  (lisp-repl-publish "lisp-clear" (jobj)))

(defun lisp-repl-transcript-text (&key (count 10) (repl *lisp-repl*))
  "The last COUNT REPL interactions as plain text, oldest first (for the agent)."
  (let ((entries (bt:with-lock-held ((lisp-repl-lock repl))
                   (reverse (subseq (lisp-repl-entries repl)
                                    0 (min count (length (lisp-repl-entries repl))))))))
    (if (null entries)
        "The Lisp REPL transcript is empty."
        (with-output-to-string (s)
          (dolist (entry entries)
            (format s "[~d] ~a> ~a~%" (lisp-entry-id entry) (lisp-entry-package entry)
                    (if (equal (lisp-entry-mode entry) "compile-file")
                        ";; compile and load the scratch buffer"
                        (string-trim '(#\Newline) (lisp-entry-input entry))))
            (let ((output (lisp-entry-output entry)))
              (when (plusp (length output))
                (format s "~a~&" (if (> (length output) 4000)
                                     (concatenate 'string (subseq output 0 4000) "…")
                                     output))))
            (dolist (note (lisp-entry-notes entry))
              (format s "; ~a: ~a~%" (getf note :severity) (getf note :message)))
            (let ((debugger (lisp-entry-debugger entry)))
              (when debugger
                (format s "!! ~a: ~a~%" (getf debugger :type) (getf debugger :condition))
                (format s "   restarts: ~{~a~^; ~}~%"
                        (mapcar (lambda (r) (format nil "~a (~a)" (first r) (second r)))
                                (getf debugger :restarts)))
                (loop for frame in (getf debugger :backtrace) for i below 15
                      do (format s "   ~d: ~a~%" i frame))))
            (case (lisp-entry-state entry)
              (:running (format s ";; still running~%"))
              (:debugger (format s ";; waiting in the debugger~%"))
              (:aborted (format s ";; evaluation aborted~%"))
              (t (if (lisp-entry-values entry)
                     (dolist (value (lisp-entry-values entry))
                       (format s "=> ~a~%" (let ((text (getf value :text)))
                                             (if (> (length text) 2000)
                                                 (concatenate 'string (subseq text 0 2000) "…")
                                                 text))))
                     (format s ";; no values~%"))))
            (terpri s))))))

;;; --- the scratch buffer ---

(defparameter *lisp-scratch-initial-text*
  ";;;; scratch.lisp -- your Lisp scratch buffer, shared with the agent.
;;;;
;;;; C-c C-c compiles the form at point, C-x C-e evaluates the form before
;;;; the cursor, C-c C-k compiles and loads the whole buffer, M-. finds a
;;;; definition, C-c C-d d describes a symbol.  Ask the agent to \"review my
;;;; scratch buffer\" and it can read it (and edit it, if you ask).

(in-package :cl-agent)

")

(defvar *lisp-scratch-lock* (bt:make-lock "cl-agent-lisp-scratch"))
(defvar *lisp-scratch* nil
  "(PATHNAME TEXT VERSION FILE-DATE) of the scratch buffer in use.")

(defun lisp-scratch-pathname () (merge-pathnames "repl/scratch.lisp" *config-directory*))
(defun lisp-scratch-history-directory () (merge-pathnames "repl/.history/" *config-directory*))

(defun %lisp-scratch ()
  "The current scratch record, (re)read when the config directory changed
or the file was edited outside cl-agent.  Caller holds *LISP-SCRATCH-LOCK*."
  (let* ((path (lisp-scratch-pathname))
         (date (ignore-errors (and (probe-file path) (file-write-date path)))))
    (unless (and *lisp-scratch* (equal (first *lisp-scratch*) path)
                 (eql (fourth *lisp-scratch*) date))
      (setf *lisp-scratch*
            (list path (if date (read-text-file path) *lisp-scratch-initial-text*)
                  (1+ (if (and *lisp-scratch* (equal (first *lisp-scratch*) path)) (third *lisp-scratch*) 0))
                  date)))
    *lisp-scratch*))

(defun lisp-scratch-contents ()
  "(values TEXT VERSION) of the scratch buffer."
  (bt:with-lock-held (*lisp-scratch-lock*)
    (destructuring-bind (path text version date) (%lisp-scratch)
      (declare (ignore path date))
      (values text version))))

(defun lisp-scratch-backup (text version)
  (let ((directory (lisp-scratch-history-directory)))
    (ensure-directories-exist directory)
    (write-string-atomically (merge-pathnames (format nil "scratch-~d-v~d.lisp" (get-universal-time) version)
                                              directory)
                             text)
    (let ((old (sort (uiop:directory-files directory "scratch-*.lisp") #'string> :key #'namestring)))
      (mapc (lambda (file) (ignore-errors (delete-file file))) (nthcdr 20 old)))))

(defun lisp-scratch-save (text &key base (by "user") client)
  "Replace the scratch buffer with TEXT, written by BY (\"user\" or \"agent\").
BASE is the version the writer last saw: if the buffer has changed since,
nothing is written and the result is (values :CONFLICT VERSION CURRENT).
Otherwise (values :SAVED VERSION).  The agent's writes back up the text
they replace in repl/.history/."
  (let ((result nil) (published nil))
    (bt:with-lock-held (*lisp-scratch-lock*)
      (destructuring-bind (path current version date) (%lisp-scratch)
        (declare (ignore date))
        (cond ((and base (/= base version) (string/= text current))
               (setf result (list :conflict version current)))
              ((string= text current)
               (setf result (list :saved version)))
              (t
               (when (equal by "agent") (lisp-scratch-backup current version))
               (ensure-directories-exist path)
               (write-string-atomically path text)
               (setf *lisp-scratch* (list path text (1+ version) (file-write-date path))
                     result (list :saved (1+ version))
                     published (jobj "version" (1+ version) "text" text "by" by
                                     "client" (json-or-null client)))))))
    (when published (lisp-repl-publish "lisp-scratch" published))
    (values-list result)))
