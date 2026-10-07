;;;; storage.lisp -- small durable-storage primitives shared by agent state.

(in-package :cl-agent)

(defun atomic-output-temporary-pathname (pathname)
  "Return a unique temporary sibling of PATHNAME.

Keeping the temporary file beside its destination makes the final rename a
single-filesystem operation.  A temporary file under /tmp, for example, could
turn the final publication into a copy and expose a partial destination."
  (let ((target (pathname pathname)))
    (make-pathname :name (format nil ".~a.~36r.tmp"
                                 (or (pathname-name target) "output")
                                 (random most-positive-fixnum))
                   :type (pathname-type target)
                   :defaults target)))

(defun call-with-atomic-output-file (pathname writer &key (if-exists :supersede))
  "Call WRITER with an output stream, then atomically publish it at PATHNAME.

If WRITER signals an error, the previous destination remains intact and the
temporary sibling is removed.  :SUPERSEDE replaces a destination atomically;
:ERROR preserves WITH-OPEN-FILE's useful refusal-to-overwrite behavior."
  (unless (member if-exists '(:supersede :error))
    (error "Atomic output supports only :SUPERSEDE or :ERROR, not ~s" if-exists))
  (let* ((target (pathname pathname))
         (temporary (atomic-output-temporary-pathname target))
         (published-p nil))
    (ensure-directories-exist target)
    (when (and (eq if-exists :error) (probe-file target))
      (error "Refusing to overwrite existing file ~a" target))
    (unwind-protect
         (progn
           (with-open-file (out temporary :direction :output
                                          :if-exists :error
                                          :if-does-not-exist :create)
             (funcall writer out)
             (finish-output out))
           (uiop:rename-file-overwriting-target temporary target)
           (setf published-p t)
           target)
      (unless published-p
        (when (probe-file temporary)
          (delete-file temporary))))))

(defun write-string-atomically (pathname string &key (if-exists :supersede))
  "Atomically replace PATHNAME with STRING and return the published pathname."
  (unless (stringp string)
    (error "Atomic string output requires a string, not ~s" string))
  (call-with-atomic-output-file pathname
                                (lambda (out) (write-string string out))
                                :if-exists if-exists))
