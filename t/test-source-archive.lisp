;;;; t/test-source-archive.lisp -- the Lisp source kept in the image
;;;; (source-archive.lisp) and the agent's lisp-source tool.

(in-package :cl-agent)

(defmacro with-source-archive ((&optional (archive '(make-hash-table :test 'equal))) &body body)
  "Run BODY with *SOURCE-ARCHIVE*'s global value ARCHIVE (tools may run on
other threads), restoring the real one after."
  `(let ((saved *source-archive*) (saved-index *source-disk-index*))
     (unwind-protect (progn (setf *source-archive* ,archive *source-disk-index* nil) ,@body)
       (setf *source-archive* saved *source-disk-index* saved-index))))

(defun write-test-source (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text out))
  path)

(defun archive-file-for-test (path)
  (setf (gethash (source-archive-key path) *source-archive*)
        (make-archived-source "test" (file-namestring path) (read-file-octets path) (file-write-date path))))

(deftest sources-are-archived-when-the-image-is-dumped ()
  (check (member 'archive-loaded-system-sources uiop:*image-dump-hook*) "a UIOP image-dump hook, so only `make build` pays")
  (let ((table (make-hash-table :test 'equal)))
    (let ((count (archive-system-sources "cl-agent" table))
          (files (remove-if-not #'probe-file (system-source-pathnames (asdf:find-system "cl-agent")))))
      (check-equal count (length files) "the .asd and every .lisp component")
      (let ((entry (gethash (source-archive-key (asdf:system-relative-pathname "cl-agent" "src/repl.lisp")) table)))
        (check entry)
        (check-equal (archived-source-system entry) "cl-agent")
        (check-equal (archived-source-path entry) "src/repl.lisp")
        (check (equalp (archived-source-octets entry)
                       (read-file-octets (asdf:system-relative-pathname "cl-agent" "src/repl.lisp"))))
        (check (typep (archived-source-octets entry) '(simple-array (unsigned-byte 8) (*))) "a byte a character")))))

(deftest the-archived-scope-is-chosen-at-build-time ()
  (let ((saved (uiop:getenv "CL_AGENT_EMBED_SOURCES")))
    (unwind-protect
         (progn
           (sb-posix:unsetenv "CL_AGENT_EMBED_SOURCES")
           (check-equal (source-archive-scope) :all)
           (setf (uiop:getenv "CL_AGENT_EMBED_SOURCES") "own")
           (check-equal (source-archive-scope) :own)
           (setf (uiop:getenv "CL_AGENT_EMBED_SOURCES") "none")
           (check-equal (source-archive-scope) :none)
           (with-source-archive ()
             (check-equal (archive-loaded-system-sources) 0)))
      (if saved (setf (uiop:getenv "CL_AGENT_EMBED_SOURCES") saved) (sb-posix:unsetenv "CL_AGENT_EMBED_SOURCES")))))

(deftest the-compiled-copy-of-a-source-file-is-the-one-read ()
  (let ((path (write-test-source (merge-pathnames "archived.lisp" *config-directory*) "(compiled)")))
    (ensure-directories-exist path)
    (with-source-archive ()
      (let ((compiled-date (file-write-date path)))
        (setf (gethash (source-archive-key path) *source-archive*)
              (make-archived-source "test" "archived.lisp" (read-file-octets path) compiled-date))
        (write-test-source path "(edited since)")
        ;; Edited a minute later: universal time less 2208988800 is Unix time.
        (let ((later (- (+ compiled-date 60) 2208988800)))
          (sb-posix:utime (uiop:native-namestring path) later later))
        (check-equal (source-file-text path :write-date compiled-date) "(compiled)" "the copy SBCL compiled")
        (check-equal (nth-value 1 (source-file-text path :write-date compiled-date)) :archive)
        (check-equal (source-file-text path) "(edited since)" "without a date: the disk's")
        (delete-file path)
        (check-equal (source-file-text path) "(compiled)" "the file is gone: the image's")))))

(deftest m-dot-shows-source-from-the-image-when-the-file-is-gone ()
  (let* ((source (write-test-source (merge-pathnames "gone.lisp" *config-directory*)
                                    (format nil ";; a file that will be deleted~%(defun cl-user::archived-test-function (x)~%  \"Doc.\"~%  (* x 2))~%")))
         (fasl (compile-file source :verbose nil :print nil)))
    (load fasl)
    (with-source-archive ()
      (archive-file-for-test source)
      (delete-file source)
      (delete-file fasl)
      (let ((definition (first (lisp-repl-definitions "archived-test-function" (find-package :cl-user)))))
        (check definition)
        (check-equal (getf definition :origin) "archive")
        (check-equal (getf definition :line) 2)
        (check (search "(* x 2)" (getf definition :snippet)))))))

(deftest lisp-source-tool-reads-the-archived-source ()
  (with-source-archive ()
    (archive-system-sources "cl-agent")
    (check (search "cl-agent (" (call-tool "lisp-source" (jobj "action" "systems"))))
    (check (search "cl-agent/src/source-archive.lisp" (call-tool "lisp-source" (jobj "action" "files" "system" "cl-agent"))))
    (let ((text (call-tool "lisp-source" (jobj "action" "read" "path" "cl-agent/src/source-archive.lisp"
                                               "start_line" 1 "end_line" 2))))
      (check (search ";;;; source-archive.lisp" text))
      (check (search "from this image" text)))
    (check (search "src/source-archive.lisp:"
                   (call-tool "lisp-source" (jobj "action" "search" "query" "REGISTER-IMAGE-DUMP-HOOK"))))
    (check (search "(defun archive-system-sources"
                   (call-tool "lisp-source" (jobj "action" "definition" "symbol" "archive-system-sources"))))
    (check (search "No source file" (call-tool "lisp-source" (jobj "action" "read" "path" "cl-agent/nope.lisp"))))))

(deftest lisp-source-tool-reads-from-disk-in-a-development-image ()
  (with-source-archive ()
    (check (search "read from disk" (call-tool "lisp-source" (jobj "action" "systems"))))
    (check (search "(in-package :lem-core)"
                   (call-tool "lisp-source" (jobj "action" "read" "path" "lem/core/src/lem.lisp" "end_line" 5)))
           "system names with a slash")))
