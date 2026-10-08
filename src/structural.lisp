;;;; structural.lisp -- immutable Clasted observations over workspace files.

(in-package :cl-agent)

(defun structural-file-revision (text)
  "Return a content revision for TEXT independent of timestamp granularity."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (babel:string-to-octets text :encoding :utf-8))))

(defun make-file-structural-snapshot (path)
  "Observe PATH once as an immutable Clasted snapshot and return it.

The revision is the exact UTF-8 content digest, so a later write is detectable
even if filesystem timestamps have coarse resolution.  This function never
writes the file."
  (let* ((resolved (file-tool-path path "structural rewrite"))
         (text (uiop:read-file-string resolved)))
    (clasted:make-snapshot :file (namestring resolved)
                           :revision (structural-file-revision text)
                           :text text)))

(defun structural-plan-current-p (plan)
  "True when PLAN still describes the exact current contents of its source file."
  (let* ((snapshot (clasted:plan-snapshot plan))
         (path (clasted:snapshot-file snapshot)))
    (and (probe-file path)
         (handler-case
             (string= (clasted:snapshot-revision snapshot)
                      (structural-file-revision (uiop:read-file-string path)))
           (error () nil)))))

(defun structural-program-on-path (name)
  "Return the first executable-like NAME found on PATH, or NIL.

The subsequent Clasted backend owns execution and will report a non-executable
file precisely; this lookup only avoids a cryptic launch error when the parser
is plainly absent."
  (or (probe-file name)
      (loop for directory in (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":")
            for candidate = (ignore-errors
                              (probe-file
                               (merge-pathnames name (uiop:ensure-directory-pathname directory))) )
            when candidate return candidate)))

(defun ensure-ast-grep-backend ()
  "Load Clasted's optional backend only when the external parser is present."
  (let ((program (structural-program-on-path "ast-grep")))
    (unless program
      (error "structural-rewrite-plan requires ast-grep on PATH; install it, then retry"))
    (asdf:load-system "clasted/ast-grep")
    (clasted:make-ast-grep-backend :program (namestring program))))

(defun plan-structural-rewrite (path language pattern replacement)
  "Return a non-writing Clasted edit plan for one immutable file observation."
  (unless (and (stringp language) (plusp (length (string-trim " " language)))
               (stringp pattern) (plusp (length pattern)) (stringp replacement))
    (error "language, pattern, and replacement must be strings; language and pattern cannot be empty"))
  (clasted:rewrite (ensure-ast-grep-backend)
                   (make-file-structural-snapshot path)
                   :language language :pattern pattern :replacement replacement))

(defun query-structural-file (path language pattern)
  "Return immutable Clasted matches for PATH without planning or writing.

Each result stays anchored to the snapshot revision, so callers can show an
auditable structural search without confusing it with a current-file claim."
  (unless (and (stringp language) (plusp (length (string-trim " " language)))
               (stringp pattern) (plusp (length pattern)))
    (error "language and pattern must be non-empty strings"))
  (let ((snapshot (make-file-structural-snapshot path)))
    (values snapshot
            (clasted:query (ensure-ast-grep-backend) snapshot
                           :language language :pattern pattern))))

(defun structural-match->plist (match)
  "Detach a Clasted match for a UI/tool response without exposing its object."
  (list :id (clasted:match-id match)
        :start-byte (clasted:match-start-byte match)
        :end-byte (clasted:match-end-byte match)
        :start (clasted:match-start match)
        :end (clasted:match-end match)
        :text (clasted:match-text match)))

(defun format-structural-query (snapshot matches)
  "Render query results with the immutable source identity they describe."
  (with-output-to-string (output)
    (format output "Structural query (read-only)~%file: ~a~%revision: ~a~%snapshot: ~a~%matches: ~d"
            (clasted:snapshot-file snapshot) (clasted:snapshot-revision snapshot)
            (clasted:snapshot-id snapshot) (length matches))
    (dolist (match matches)
      (format output "~%[~d,~d) ~a" (clasted:match-start match)
              (clasted:match-end match) (clasted:match-text match)))))

(defun publish-structural-plans (plans)
  "Publish a nonempty list of plans only when every source revision is current.

All guards are checked before the first write, preventing a stale member from
causing a partial batch.  Individual writes use the normal atomic publisher;
cross-file filesystem transactions are not generally portable, so an I/O
failure after that point is reported rather than disguised as all-or-nothing."
  (unless (and (listp plans) plans (every (lambda (plan) (typep plan 'clasted:edit-plan)) plans))
    (error "publish-structural-plans requires a nonempty list of edit plans"))
  (let ((paths (mapcar (lambda (plan) (clasted:snapshot-file (clasted:plan-snapshot plan))) plans)))
    (unless (= (length paths) (length (remove-duplicates paths :test #'string=)))
      (error "A structural publication batch may contain only one plan per file"))
    (dolist (plan plans)
      (unless (structural-plan-current-p plan)
        (error "Structural plan is stale for ~a; observe and plan again"
               (clasted:snapshot-file (clasted:plan-snapshot plan)))))
    (dolist (plan plans)
      (write-string-atomically (clasted:snapshot-file (clasted:plan-snapshot plan))
                               (clasted:plan-preview plan)))
    (mapcar (lambda (plan) (clasted:snapshot-file (clasted:plan-snapshot plan))) plans)))

(defun format-structural-plan (plan)
  "Render a plan's immutable identity, revision guard, edits and full preview."
  (let ((snapshot (clasted:plan-snapshot plan)))
    (format nil "Structural rewrite plan (preview only)~%file: ~a~%revision: ~a~%snapshot: ~a~%edits: ~d~%~%preview:~%~a"
            (clasted:snapshot-file snapshot)
            (clasted:snapshot-revision snapshot)
            (clasted:snapshot-id snapshot)
            (length (clasted:plan-edits plan))
            (clasted:plan-preview plan))))
