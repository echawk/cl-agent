(in-package :cl-agent)

(defun temporary-storage-test-path (name)
  (merge-pathnames (format nil "cl-agent-storage-~a-~a.txt" name (gensym))
                   (uiop:temporary-directory)))

(deftest atomic-output-publishes-replacement ()
  (let ((path (temporary-storage-test-path "replace")))
    (unwind-protect
         (progn
           (write-string-atomically path "before")
           (write-string-atomically path "after")
           (check-equal (uiop:read-file-string path) "after"))
      (when (probe-file path) (delete-file path)))))

(deftest atomic-output-keeps-previous-file-when-writer-fails ()
  (let ((path (temporary-storage-test-path "failure")))
    (unwind-protect
         (progn
           (write-string-atomically path "known-good")
           (check-condition error
                            (call-with-atomic-output-file
                             path
                             (lambda (out)
                               (write-string "partial" out)
                               (error "intentional writer failure"))))
           (check-equal (uiop:read-file-string path) "known-good"))
      (when (probe-file path) (delete-file path)))))

(deftest atomic-output-error-does-not-overwrite-existing-file ()
  (let ((path (temporary-storage-test-path "exists")))
    (unwind-protect
         (progn
           (write-string-atomically path "known-good")
           (check-condition error (write-string-atomically path "new" :if-exists :error))
           (check-equal (uiop:read-file-string path) "known-good"))
      (when (probe-file path) (delete-file path)))))
