;;;; source-archive.lisp -- the Lisp source of every loaded system, kept in
;;;; the image itself, so a built bin/cl-agent can show any definition's
;;;; source (the Lisp tab's M-., the lisp-source tool) on a machine without
;;;; the source tree, or after the tree has moved on.
;;;;
;;;; ARCHIVE-LOADED-SYSTEM-SOURCES runs as a UIOP image-dump hook, so only
;;;; when `make build` saves the image (never on an ordinary load): it reads
;;;; each loaded ASDF system's .asd and .lisp files as UTF-8 octets (a byte a
;;;; character, where a Lisp string would take four) with their write dates.
;;;; CL_AGENT_EMBED_SOURCES at build time chooses: "all" (the default, about
;;;; 23 MB), "own" (cl-agent's, about 1 MB) or "none".
;;;;
;;;; SOURCE-FILE-OCTETS answers for a pathname from whichever copy fits:
;;;; given the write date SBCL recorded when compiling a definition, the copy
;;;; with that date; otherwise the file on disk, else the archived one.

(in-package :cl-agent)

(defstruct (archived-source (:constructor make-archived-source (system path octets write-date)))
  "One archived file: its SYSTEM's name, PATH relative to the system's
directory, its OCTETS (UTF-8) and its WRITE-DATE when archived."
  system path octets write-date)

(defvar *source-archive* (make-hash-table :test 'equal)
  "Absolute native namestring -> ARCHIVED-SOURCE.")

(defun source-archive-key (pathname)
  (ignore-errors (uiop:native-namestring (translate-logical-pathname (merge-pathnames pathname)))))

(defun read-file-octets (pathname)
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun system-source-pathnames (system)
  "SYSTEM's .asd file and every CL-SOURCE-FILE component's pathname."
  (let ((files (list (asdf:system-source-file system))))
    (labels ((walk (component)
               (typecase component
                 (asdf:cl-source-file (push (asdf:component-pathname component) files))
                 (asdf:module (mapc #'walk (asdf:component-children component))))))
      (walk system))
    (remove-duplicates (remove nil (nreverse files)) :test #'equal :key #'source-archive-key)))

(defun archive-system-sources (name &optional (archive *source-archive*))
  "Archive system NAME's source files into ARCHIVE; return how many."
  (let* ((system (asdf:find-system name nil))
         (directory (and system (asdf:system-source-directory system)))
         (count 0))
    (when directory
      (dolist (pathname (system-source-pathnames system) count)
        (let ((key (source-archive-key pathname)))
          (when (and key (probe-file pathname) (not (gethash key archive)))
            (setf (gethash key archive)
                  (make-archived-source (asdf:component-name system)
                                        (enough-namestring pathname directory)
                                        (read-file-octets pathname)
                                        (file-write-date pathname)))
            (incf count)))))))

(defun source-archive-scope ()
  (let ((scope (string-downcase (or (uiop:getenv "CL_AGENT_EMBED_SOURCES") ""))))
    (cond ((member scope '("none" "no" "0") :test #'string=) :none)
          ((member scope '("own" "cl-agent") :test #'string=) :own)
          (t :all))))

(defun archive-loaded-system-sources ()
  "Archive the sources of the loaded systems (see CL_AGENT_EMBED_SOURCES).
Run while the image is dumped."
  (clrhash *source-archive*)
  (setf *source-disk-index* nil)
  (ecase (source-archive-scope)
    (:none nil)
    (:own (archive-system-sources "cl-agent"))
    (:all (dolist (name (asdf:already-loaded-systems))
            (ignore-errors (archive-system-sources name)))))
  (hash-table-count *source-archive*))

(uiop:register-image-dump-hook 'archive-loaded-system-sources)

;;; --- the index the lisp-source tool reads ---
;;;
;;; The archive in a built image; in a development image (nothing dumped
;;; yet), the same entries for the loaded systems' files on disk, with no
;;; octets: their text is read from disk when wanted.

(defvar *source-disk-index* nil)

(defun source-index ()
  (if (plusp (hash-table-count *source-archive*))
      *source-archive*
      (or *source-disk-index*
          (let ((index (make-hash-table :test 'equal)))
            (dolist (name (asdf:already-loaded-systems) (setf *source-disk-index* index))
              (ignore-errors
               (let* ((system (asdf:find-system name nil))
                      (directory (and system (asdf:system-source-directory system))))
                 (when directory
                   (dolist (pathname (system-source-pathnames system))
                     (let ((key (source-archive-key pathname)))
                       (when (and key (not (gethash key index)))
                         (setf (gethash key index)
                               (make-archived-source (asdf:component-name system)
                                                     (enough-namestring pathname directory)
                                                     nil nil)))))))))))))

(defun archived-source-text (key entry)
  "ENTRY's text: its archived octets, or the file KEY on disk."
  (let ((octets (or (archived-source-octets entry) (ignore-errors (read-file-octets key)))))
    (and octets (babel:octets-to-string octets :encoding :utf-8 :errorp nil))))

;;; --- reading ---

(defun archived-source (pathname)
  (let ((key (source-archive-key pathname)))
    (and key (gethash key *source-archive*))))

(defun source-file-octets (pathname &key write-date)
  "PATHNAME's contents as UTF-8 octets, or NIL: the archived copy when it is
the one WRITE-DATE names (the date SBCL recorded compiling it) or the file
is gone, else the file on disk.  Second value: :ARCHIVE or :DISK."
  (let* ((entry (archived-source pathname))
         (file (ignore-errors (probe-file (translate-logical-pathname pathname))))
         (disk-date (and file (ignore-errors (file-write-date file)))))
    (cond ((and entry (or (null file)
                          (and write-date (eql write-date (archived-source-write-date entry))
                               (not (eql write-date disk-date)))))
           (values (archived-source-octets entry) :archive))
          (file (values (ignore-errors (read-file-octets file)) :disk))
          (entry (values (archived-source-octets entry) :archive)))))

(defun source-file-text (pathname &key write-date)
  "PATHNAME's text (see SOURCE-FILE-OCTETS), or NIL."
  (multiple-value-bind (octets origin) (source-file-octets pathname :write-date write-date)
    (and octets (values (babel:octets-to-string octets :encoding :utf-8 :errorp nil) origin))))

(defun source-archive-systems ()
  "(SYSTEM . FILE-COUNT) of SOURCE-INDEX, by system name."
  (let ((counts (make-hash-table :test 'equal)))
    (loop for entry being the hash-values of (source-index)
          do (incf (gethash (archived-source-system entry) counts 0)))
    (sort (loop for system being the hash-keys of counts using (hash-value count) collect (cons system count))
          #'string< :key #'car)))

(defun source-archive-files (system)
  "(KEY . ARCHIVED-SOURCE) of SYSTEM's files in SOURCE-INDEX, by path."
  (sort (loop for key being the hash-keys of (source-index) using (hash-value entry)
              when (string-equal (archived-source-system entry) system) collect (cons key entry))
        #'string< :key (lambda (pair) (archived-source-path (cdr pair)))))

(defun find-archived-source (name)
  "SOURCE-INDEX's (KEY . ARCHIVED-SOURCE) for NAME: an absolute path, or
\"SYSTEM/RELATIVE-PATH\" (cl-agent/src/repl.lisp)."
  (let* ((key (source-archive-key name))
         (entry (and key (gethash key (source-index)))))
    (if entry
        (cons key entry)
        ;; System names may hold a slash themselves (lem/core): try the
        ;; longest that prefixes NAME first.
        (dolist (system (sort (mapcar #'car (source-archive-systems)) #'> :key #'length))
          (when (and (> (length name) (1+ (length system)))
                     (string-equal system name :end2 (length system))
                     (char= (char name (length system)) #\/))
            (let ((found (find (subseq name (1+ (length system))) (source-archive-files system)
                               :key (lambda (pair) (archived-source-path (cdr pair))) :test #'string=)))
              (when found (return found))))))))
