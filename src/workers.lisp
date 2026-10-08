;;;; workers.lisp -- isolated SBCL worker processes for bounded agent work.

(in-package :cl-agent)

(defvar *subagent-worker-pool* nil)
(defvar *subagent-worker-pool-lock*
  (bordeaux-threads:make-lock "cl-agent subagent worker pool"))

(defun subagent-worker-root ()
  "Directory in which compatible worker images are retained."
  (merge-pathnames "workers/images/" *config-directory*))

(defun subagent-worker-command ()
  "Return an argv that starts a pristine cl-agent worker protocol runtime.

The child starts from source instead of inheriting the parent image.  This is
the isolation boundary: no parent session, tool registry mutations, or dynamic
bindings can leak into the worker heap."
  (let ((root (asdf:system-source-directory "cl-agent")))
    ;; Match sbcl-workers' own clean-runtime bootstrap.  Loading BOOT.LISP
    ;; here is subtly wrong: its OCICL bootstrap retains the worker protocol's
    ;; stdio during launch on SBCL/macOS.  A closed ASDF registry gives the
    ;; child every pinned dependency without inheriting parent streams.
    (list "sbcl"
          "--noinform" "--non-interactive"
          "--eval" "(require :asdf)"
          "--eval" (format nil
                             "(asdf:initialize-source-registry '(:source-registry (:directory #P~S) (:tree #P~S) (:tree #P~S) :inherit-configuration))"
                             (namestring root) (namestring (merge-pathnames "ocicl/" root))
                             (namestring (merge-pathnames "third-party/" root)))
          "--eval" (format nil "(asdf:load-asd #P~S)"
                             (namestring (merge-pathnames "cl-agent.asd" root)))
          "--eval" "(asdf:load-system :cl-agent)"
          "--eval" "(cl-agent::run-subagent-worker-runtime)")))

(defun subagent-worker-environment ()
  (let ((images (subagent-worker-root)))
    (ensure-directories-exist images)
    (sbcl-workers:sbcl-worker-environment-create
     :pristine-command #'subagent-worker-command
     :working-directory (asdf:system-source-directory "cl-agent")
     :image-root images
     :evaluation-package "CL-AGENT")))

(defun subagent-worker-pool ()
  "Return the process-isolated, named worker pool.

Workers are persistent only within this host process.  They are explicitly
stoppable, and their heaps never alias an AGENT-SESSION in the host."
  (or *subagent-worker-pool*
      (bordeaux-threads:with-lock-held (*subagent-worker-pool-lock*)
        (or *subagent-worker-pool*
            (setf *subagent-worker-pool*
                  (sbcl-workers:sbcl-worker-pool-create
                   (subagent-worker-environment)))))))

(defun stop-subagent-worker (name)
  "Cancel any active request for NAME, then stop and forget its process."
  (let ((pool (subagent-worker-pool)))
    (let ((worker (ignore-errors (sbcl-workers:sbcl-worker-pool-worker pool name))))
      (when worker (ignore-errors (sbcl-workers:sbcl-worker-cancel-request worker))))
    (sbcl-workers:sbcl-worker-pool-stop pool name :if-missing :ignore)))

(defun run-subagent-worker-evaluation (name form)
  "Evaluate one FORM string in isolated worker NAME and return its response.

This small primitive is deliberately public to the agent's reflective surface:
callers can inspect the exact readable protocol response instead of treating a
subprocess as opaque."
  (unless (and (stringp name) (sbcl-workers:sbcl-worker-name-p name))
    (error "Invalid subagent worker name: ~s" name))
  (unless (and (stringp form) (plusp (length form)))
    (error "A worker evaluation needs one non-empty source form."))
  (sbcl-workers:sbcl-worker-request
   (sbcl-workers:sbcl-worker-pool-worker (subagent-worker-pool) name)
   :eval (list :forms (list form))))

(defun run-subagent-worker-runtime ()
  "Entrypoint used only by SUBAGENT-WORKER-COMMAND in a child SBCL."
  (sbcl-workers:sbcl-worker-main :evaluation-package "CL-AGENT"))
