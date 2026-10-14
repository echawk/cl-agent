;;;; memory.lisp -- what the agent remembers across sessions: facts,
;;;; lessons, the user's preferences, a project's gotchas.
;;;;
;;;;   - remember / recall / forget tools write and read short entries: a
;;;;     key, a body of a sentence or two, tags.  Remembering a key that
;;;;     exists updates it, so the store never fills with near-duplicates.
;;;;   - Two scopes: global (every project) and the current project's, the
;;;;     project being the git repository the working directory is in (or the
;;;;     directory itself), keyed by a digest of its root path.
;;;;   - Every model request carries a digest of both (keys and first lines,
;;;;     MEMORY-SYSTEM-NOTE) appended to its system message -- every request,
;;;;     not just a session's first, and only in the request: the session's
;;;;     durable history is unchanged, so a memory forgotten today is not
;;;;     replayed tomorrow.  The :memory setting turns it off.
;;;;   - Stored as data-only records under config/memory/ (global.sexp,
;;;;     projects/<digest>.sexp) through SEXP-STORE, written atomically under
;;;;     a lock, so subagents and other sessions remember side by side.

(in-package :cl-agent)

(setinka:define-setting :memory (setinka:boolean-setting :registry *agent-setting-registry*)
  :label "Memory in every request" :group :agent :scope :durable
  :documentation "Whether each model request is told what the agent remembers (the remember tool)."
  :environment "CL_AGENT_MEMORY" :default t)

(defparameter *memory-digest-entries* 60
  "The most entries a request's digest lists; recall finds the rest.")

(defun memory-directory () (merge-pathnames "memory/" *config-directory*))

(defun memory-project-root ()
  "The current project: the git repository holding the working directory,
else the directory itself."
  (let ((root (ignore-errors
               (multiple-value-bind (out err status)
                   (uiop:run-program '("git" "rev-parse" "--show-toplevel")
                                     :output :string :error-output nil :ignore-error-status t
                                     :directory (uiop:getcwd))
                 (declare (ignore err))
                 (and (zerop status) (string-trim '(#\Newline #\Space) out))))))
    (uiop:native-namestring (uiop:ensure-directory-pathname (if (plusp (length root)) root (uiop:getcwd))))))

(defun memory-store-path (scope)
  (merge-pathnames (if (eq scope :global)
                       "global.sexp"
                       (format nil "projects/~a.sexp"
                               (subseq (structural-file-revision (memory-project-root)) 0 16)))
                   (memory-directory)))

(defun memory-record-p (record)
  (and (consp record) (eq (first record) :cl-agent-memory)
       (eql (getf (rest record) :version) 1)
       (listp (getf (rest record) :entries))
       (sexp-store:record-finite-p record)))

(defun memory-store (scope)
  (let ((path (memory-store-path scope))
        (root (and (eq scope :project) (memory-project-root))))
    (make-instance 'sexp-store:snapshot-store
                   :pathname path
                   :lock-pathname (make-pathname :type "lock" :defaults path)
                   :initial-state (lambda () '())
                   :validator #'memory-record-p
                   :decoder (lambda (record) (copy-list (getf (rest record) :entries)))
                   :encoder (lambda (entries)
                              (list :cl-agent-memory :version 1 :root root :entries entries)))))

(defun memory-entries (scope)
  "SCOPE's entries (:global or :project), each tagged with its scope."
  (mapcar (lambda (entry) (list* :scope scope entry))
          (ignore-errors (sexp-store:store-read (memory-store scope)))))

(defun all-memory-entries ()
  (append (memory-entries :project) (memory-entries :global)))

(defun normalize-memory-text (text what &key (limit 2000))
  (let ((trimmed (and (stringp text) (string-trim '(#\Space #\Tab #\Newline) text))))
    (unless (and trimmed (plusp (length trimmed)))
      (error "Give the memory's ~a." what))
    (when (> (length trimmed) limit)
      (error "The memory's ~a is longer than ~d characters: keep it to the point." what limit))
    trimmed))

(defun memory-remember (key body &key tags (scope :project))
  "Remember BODY under KEY in SCOPE, updating the entry KEY names if there is
one.  Returns (values entry :added-or-:updated)."
  (let ((key (normalize-memory-text key "key" :limit 120))
        (body (normalize-memory-text body "body"))
        (tags (remove-if-not (lambda (tag) (and (stringp tag) (plusp (length tag)))) tags))
        (now (get-universal-time)))
    ;; STORE-TRANSACT: (values new-state result write-p).
    (values-list
      (sexp-store:store-transact
       (memory-store scope)
       (lambda (entries)
         (let ((existing (find key entries :key (lambda (entry) (getf entry :key)) :test #'string-equal)))
           (if existing
               (let ((updated (list :id (getf existing :id) :key (getf existing :key) :body body :tags tags
                                    :created (getf existing :created) :updated now)))
                 (values (substitute updated existing entries) (list (list* :scope scope updated) :updated) t))
               (let ((entry (list :id (format nil "m~36r~36r" now (random (expt 36 4))) :key key :body body
                                  :tags tags :created now :updated now)))
                 (values (append entries (list entry)) (list (list* :scope scope entry) :added) t)))))))))

(defun memory-forget (id-or-key)
  "Forget the entry with ID-OR-KEY (an id, or a key) in either scope.
Returns the forgotten entry, or NIL."
  (dolist (scope '(:project :global))
    (let ((gone (sexp-store:store-transact
                 (memory-store scope)
                 (lambda (entries)
                   (let ((entry (find-if (lambda (entry)
                                           (or (equal (getf entry :id) id-or-key)
                                               (string-equal (getf entry :key) id-or-key)))
                                         entries)))
                     (if entry
                         (values (remove entry entries) (list* :scope scope entry) t)
                         (values entries nil nil)))))))
      (when gone (return gone)))))

(defun memory-matches (query tag)
  "Entries whose key or body contains QUERY (any case) and that carry TAG,
either being optional."
  (remove-if-not (lambda (entry)
                   (and (or (null query)
                            (search query (getf entry :key) :test #'char-equal)
                            (search query (getf entry :body) :test #'char-equal))
                        (or (null tag) (member tag (getf entry :tags) :test #'string-equal))))
                 (all-memory-entries)))

(defun memory-system-note ()
  "What the agent remembers, as a note for the system message, or NIL."
  (let ((entries (all-memory-entries)))
    (when entries
      (with-output-to-string (out)
        (format out "## What you remember~%From earlier sessions (the remember tool; recall gives the full text, forget drops one that is wrong):~%")
        (loop for entry in entries repeat *memory-digest-entries*
              do (format out "- [~(~a~)] ~a: ~a~%" (getf entry :scope) (getf entry :key)
                         (first-line (getf entry :body) 160)))
        (when (> (length entries) *memory-digest-entries*)
          (format out "(~d more: recall finds them.)~%" (- (length entries) *memory-digest-entries*)))))))

(defun with-memory-note (session messages)
  "MESSAGES for one request, the system message carrying the memory note
when SESSION's :memory setting is on and there is anything remembered."
  (let ((note (and (ignore-errors (session-setting-value session :memory))
                   (ignore-errors (memory-system-note)))))
    (if (and note messages (equal (getf (first messages) :role) "system"))
        (cons (list* :content (format nil "~a~%~%~a" (or (getf (first messages) :content) "") note)
                     (alexandria:remove-from-plist (first messages) :content))
              (rest messages))
        messages)))

;;; --- the tools ---

(defun format-memory-entry (entry)
  (format nil "[~a] ~a (~(~a~)~@[; tags: ~{~a~^, ~}~])~%  ~a"
          (getf entry :id) (getf entry :key) (getf entry :scope) (getf entry :tags) (getf entry :body)))

(define-tool remember (args)
    (:description "Remember something for later sessions: a fact you confirmed, a lesson learned the hard way, the user's preference, a project's gotcha or convention. Give a short key and a body of a sentence or two; remembering a key you already have updates it (so keep keys stable: \"test-command\", not a new phrasing each time). scope project (default) is this repository; global is every project. Every request shows you what you remember, so do not store what the repository or conversation already says, or anything secret."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "key" (jobj "type" "string" "description" "A short, stable name, e.g. \"test-command\".")
                 "body" (jobj "type" "string" "description" "The fact, lesson or preference, briefly.")
                 "tags" (jobj "type" "array" "items" (jobj "type" "string"))
                 "scope" (jobj "type" "string" "enum" (list "project" "global")))
           "required" (list "key" "body")))
  (multiple-value-bind (entry status)
      (memory-remember (jget args "key") (jget args "body")
                       :tags (string-list (jget args "tags"))
                       :scope (if (equal (jget args "scope") "global") :global :project))
    (format nil "~:[Remembered~;Updated~] ~a (~(~a~), id ~a)."
            (eq status :updated) (getf entry :key) (getf entry :scope) (getf entry :id))))

(define-tool recall (args)
    (:description "Search what you remember (see remember): query matches keys and bodies, any case; tag narrows by tag; neither lists everything. Gives each entry's id, scope, tags and full body."
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties" (jobj "query" (jobj "type" "string") "tag" (jobj "type" "string"))
           "required" :empty-array))
  (let ((found (memory-matches (jget args "query") (jget args "tag"))))
    (if found
        (format nil "~d memor~:@p:~%~{~a~^~%~}" (length found) (mapcar #'format-memory-entry found))
        "Nothing remembered matches.")))

(define-tool forget (args)
    (:description "Forget a memory that is wrong or no longer true, by its id or key (see recall)."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties" (jobj "id" (jobj "type" "string" "description" "The entry's id, or its key."))
           "required" (list "id")))
  (let ((gone (memory-forget (jget args "id"))))
    (if gone
        (format nil "Forgot ~a (~(~a~))." (getf gone :key) (getf gone :scope))
        (format nil "Nothing remembered has id or key ~s." (jget args "id")))))
