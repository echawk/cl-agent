;;;; events.lisp -- small, in-memory observation stream.

(in-package :cl-agent)

(defstruct agent-event
  "A typed observation emitted by the running agent.  Events deliberately do
not control execution; hooks remain the interception mechanism."
  id time kind component payload)

(defvar *event-sequence* 0)
(defvar *event-subscribers* nil
  "Functions called with each AGENT-EVENT.  Subscribers are observers only.")

(defvar *current-session*)
(defvar *config-directory*)
(defvar *session-id-counter* 0)
(defvar *session-event-id-counter* 0)
(defvar *session-turn-id-counter* 0)

(defun high-volume-durable-id (kind counter)
  "Produce an inspectable timestamp/counter ID for high-frequency records.

Idsmall is retained for externally visible low-volume artifacts (generations,
debug receipts, ACP sessions).  Session mechanics can create hundreds of
events in one second, beyond its deliberately bounded collision probe range."
  (format nil "~(~a~)-~36r-~36r" kind (get-universal-time) (funcall counter)))

(defun session-events-root ()
  "The durable event-store root.  Each session owns an append-only directory."
  (merge-pathnames "state/sessions/" *config-directory*))

(defun session-event-directory (session-id)
  (merge-pathnames (format nil "~a/events/" session-id) (session-events-root)))

(defun session-blob-directory (session-id)
  "Directory of immutable content-addressed values owned by SESSION-ID."
  (merge-pathnames (format nil "~a/blobs/" session-id) (session-events-root)))

(defun session-blob-pathname (session-id digest)
  (merge-pathnames (format nil "~a.sexp" digest) (session-blob-directory session-id)))

(defun session-content-digest (content)
  "Return the stable SHA-256 digest for UTF-8 CONTENT."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (babel:string-to-octets content :encoding :utf-8))))

(defun write-session-blob (session content &key (media-type "text/plain"))
  "Atomically retain CONTENT once and return a serializable blob reference."
  (unless (stringp content) (error "Session blobs currently require text, not ~s" content))
  (let* ((digest (session-content-digest content))
         (path (session-blob-pathname (session-id session) digest)))
    (unless (probe-file path)
      (sexp-store:snapshot-write path
                                 (list :schema-version 1 :digest digest :media-type media-type
                                       :bytes (length (babel:string-to-octets content :encoding :utf-8))
                                       :content content)
                                 :require-absent t))
    (list :algorithm "sha256" :digest digest :media-type media-type
          :bytes (length (babel:string-to-octets content :encoding :utf-8)))))

(defun read-session-blob (session-id reference)
  "Return the complete text named by a blob REFERENCE, rejecting corrupt data."
  (let ((path (session-blob-pathname session-id (getf reference :digest))))
    (multiple-value-bind (record complete-p) (sexp-store:snapshot-read path)
      (unless (and complete-p (listp record)
                   (string= (getf record :digest) (getf reference :digest))
                   (stringp (getf record :content)))
        (error "Session blob ~a is missing or invalid" (getf reference :digest)))
      (getf record :content))))

(defun session-manifest-pathname (session-id)
  (merge-pathnames (format nil "~a/session.sexp" session-id) (session-events-root)))

(defun session-event-pathname (session-id sequence)
  (merge-pathnames (format nil "~12,'0d.sexp" sequence)
                   (session-event-directory session-id)))

(defun session-event-lock-pathname (session-id)
  "Stable advisory lock shared by all writers and recovery readers."
  (merge-pathnames (format nil "~a/events.lock" session-id) (session-events-root)))

(defun call-with-session-event-lock (session-id function)
  "Call FUNCTION under the process-shared session writer lock."
  (let ((lock (session-event-lock-pathname session-id)))
    (ensure-directories-exist lock)
    (ls-flock:call-with-file-lock lock function)))

(defun allocate-session-id ()
  "Allocate a short ID without exhausting Idsmall's same-second seed space.

Many independent ACP/test sessions can start in one second.  Idsmall supplies
the timestamped base; this process-local suffix avoids repeatedly asking it to
search a finite seed range while manifests protect against a stale collision."
  (loop
    for identifier = (high-volume-durable-id :session
                                              (lambda () (incf *session-id-counter*)))
    unless (probe-file (session-manifest-pathname identifier)) return identifier))

(defun allocate-session-event-id ()
  "Return a collision-free in-process event ID without Idsmall seed exhaustion."
  (high-volume-durable-id :event (lambda () (incf *session-event-id-counter*))))

(defun allocate-session-turn-id ()
  "Return a unique turn identifier without depending on a bounded timestamp seed."
  (high-volume-durable-id :turn (lambda () (incf *session-turn-id-counter*))))

(defun make-session-event (session kind &key parent-id component status payload)
  "Build a data-only, versioned event envelope for SESSION."
  (let ((sequence (incf (session-event-sequence session))))
    (list :schema-version 1
          :id (allocate-session-event-id)
          :sequence sequence :time (get-universal-time)
          :session-id (session-id session) :turn-id (session-current-turn-id session)
          :parent-id parent-id :kind kind :component component :status status
          :payload payload)))

(defun persist-session-manifest (session &key parent-session-id)
  "Publish the small session index record used for listing and recovery."
  (let* ((path (session-manifest-pathname (session-id session)))
         (old (and (probe-file path) (ignore-errors (nth-value 0 (sexp-store:snapshot-read path)))))
         (parent (or parent-session-id (getf old :parent-session-id))))
    (sexp-store:snapshot-write
     path
     (list :schema-version 1 :id (session-id session) :created-at (session-created-at session)
           :parent-session-id parent :last-sequence (session-event-sequence session)))))

(defun %session-event-paths (session-id)
  (sort (copy-list (directory (merge-pathnames "*.sexp" (session-event-directory session-id))))
        #'string< :key #'namestring))

(defun repair-session-event-tail (session-id)
  "Remove only a malformed final event snapshot; reject every other corruption.

Atomic event snapshots normally prevent torn writes.  This defensive recovery
handles an interrupted/manual partial tail without silently accepting a gap or
corruption in the middle of a durable history.  Returns true iff a tail was
removed."
  (call-with-session-event-lock
   session-id
   (lambda ()
     (let ((paths (%session-event-paths session-id)) (expected 1) (repaired nil))
       (loop for path in paths for tail-p = (eq path (car (last paths))) do
         (handler-case
             (multiple-value-bind (event complete-p) (sexp-store:snapshot-read path)
               (unless (and complete-p (listp event) (= (getf event :schema-version) 1)
                            (= (getf event :sequence) expected))
                 (if tail-p
                     (progn (delete-file path) (setf repaired t) (return))
                     (error "Session ~a has corrupt event data at ~a" session-id path)))
               (incf expected))
           (error (condition)
             (if tail-p
                 (progn (ignore-errors (delete-file path)) (setf repaired t) (return))
                 (error "Session ~a has corrupt event data at ~a: ~a" session-id path condition)))))
       repaired))))

(defun record-session-event (session kind &key parent-id component status payload)
  "Durably append KIND before notifying in-memory observers.

Each envelope is one `sexp-store` snapshot named by its monotonic sequence.
That makes publication atomic and recovery conservative: a missing or invalid
tail is ignored, while a gap in the middle is reported by replay rather than
silently inventing history."
  (bordeaux-threads:with-lock-held ((session-event-lock session))
    (call-with-session-event-lock
     (session-id session)
     (lambda ()
       ;; A second process may have appended since this image last wrote.
       ;; Refresh the in-memory sequence while holding the shared writer lock.
       (let ((manifest (ignore-errors (nth-value 0 (sexp-store:snapshot-read
                                                   (session-manifest-pathname (session-id session)))))))
         (when manifest (setf (session-event-sequence session)
                               (max (session-event-sequence session) (or (getf manifest :last-sequence) 0)))))
       (let ((event (make-session-event session kind :parent-id parent-id
                                        :component component :status status :payload payload)))
         (sexp-store:snapshot-write
          (session-event-pathname (session-id session) (getf event :sequence)) event :require-absent t)
         (persist-session-manifest session)
         (emit-event kind :component component :payload event)
         (when (fboundp 'ui-session-event)
           (ignore-errors (ui-session-event (session-frontend session) event)))
         event)))))

(defun read-session-events (session-id)
  "Read SESSION-ID's complete durable history, rejecting a missing middle event."
  (repair-session-event-tail session-id)
  (let ((paths (%session-event-paths session-id))
        (expected 1) (events nil))
    (dolist (path paths (nreverse events))
      (multiple-value-bind (event complete-p) (sexp-store:snapshot-read path)
        (unless (and complete-p (listp event) (= (getf event :schema-version) 1)
                     (= (getf event :sequence) expected))
          (error "Session ~a has an invalid or non-contiguous event log at ~a" session-id path))
        (incf expected)
        (push event events)))))

(defun project-session-messages (events &optional through-sequence)
  "Rebuild provider messages from durable events without running tools again."
  (loop with messages = nil
        for event in events
        while (or (null through-sequence) (<= (getf event :sequence) through-sequence))
        for kind = (getf event :kind) for payload = (getf event :payload)
        do (cond
             ((eq kind :conversation-rewound)
              (setf messages (project-session-messages events
                                                        (getf payload :through-sequence))))
             ((and (member kind '(:session-created :user-message-accepted
                                  :assistant-response-finished :tool-result-recorded
                                  :tool-call-unknown-outcome :system-message-recorded))
                   (getf payload :message))
              (let ((message (copy-tree (getf payload :message)))
                    (blob (getf payload :content-blob)))
                (when blob
                  (setf (getf message :content)
                        (read-session-blob (getf event :session-id) blob)))
                (setf messages (append messages (list message))))))
        finally (return messages)))

(defun list-durable-sessions ()
  "Return durable session manifests, newest first, without constructing sessions."
  (let ((root (session-events-root)))
    (when (probe-file root)
      (sort (loop for path in (directory (merge-pathnames "*/session.sexp" root))
                  for manifest = (ignore-errors (nth-value 0 (sexp-store:snapshot-read path)))
                  when manifest collect manifest)
            #'> :key (lambda (manifest) (or (getf manifest :created-at) 0))))))

(defun emit-event (kind &key component payload)
  "Publish a small in-memory event and return it.

Subscriber failures are isolated: observability must not change agent control
flow.  Durable event storage is intentionally a later layer."
  (let ((event (make-agent-event :id (incf *event-sequence*)
                                 :time (get-universal-time)
                                 :kind kind :component component :payload payload)))
    (dolist (subscriber *event-subscribers*)
      (handler-case (funcall subscriber event)
        (error (condition)
          (format *error-output* "~&[event subscriber] error: ~a~%" condition))))
    event))

(defun subscribe-events (function)
  "Add FUNCTION to the in-memory event subscribers and return it."
  (pushnew function *event-subscribers* :test #'eq)
  function)

(defun unsubscribe-events (function)
  "Remove FUNCTION from the in-memory event subscribers."
  (setf *event-subscribers* (remove function *event-subscribers* :test #'eq))
  function)
