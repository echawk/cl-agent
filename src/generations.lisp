;;;; generations.lisp -- retained SBCL image checkpoints and recovery selection.

(in-package :cl-agent)

(defparameter *generation-manifest-version* 1
  "Version of the cl-agent metadata carried by SBCL generation manifests.")

(defun generations-directory ()
  "Directory holding retained SBCL cores and their manifests."
  (merge-pathnames "state/generations/" *config-directory*))

(defun current-generation-path ()
  "Atomic pointer to the generation selected for the next recovery boot."
  (merge-pathnames "state/current-generation.sexp" *config-directory*))

(defun generation-store-write-form (pathname form)
  "Publish one generation artifact through the shared S-expression store."
  (sexp-store:snapshot-write pathname form))

(defun generation-store-read-form (pathname)
  "Read exactly one complete generation artifact, never a partial record."
  (multiple-value-bind (form complete-p) (sexp-store:snapshot-read pathname)
    (unless complete-p
      (error "Generation artifact ~a is not one complete snapshot" pathname))
    form))

(defun validate-agent-generation-manifest (properties pathname)
  "Reject manifests not owned by this cl-agent generation format."
  (unless (and (eql (getf properties :cl-agent-generation) *generation-manifest-version*)
               (listp (getf properties :committed-mutations)))
    (error "Unsupported cl-agent generation manifest at ~a" pathname))
  t)

(defun agent-generation-store ()
  "Return the generation store rooted in the active config directory.

Both library-owned manifests and its current-generation pointer go through
SEXP-STORE, so the checkpoint library and ordinary durable state share the
same atomic, exact-one-form persistence contract."
  (sbcl-generations:make-generation-store
   :root (generations-directory)
   :current-pathname (current-generation-path)
   :manifest-version *generation-manifest-version*
   :manifest-validator #'validate-agent-generation-manifest
   :write-function #'generation-store-write-form
   :read-function #'generation-store-read-form))

(defun committed-mutation-ids ()
  "Return committed mutation IDs in durable journal order.

The scan intentionally trusts only complete SEXP-STORE snapshots.  A torn or
foreign journal is ignored here; mutation recovery can surface it separately
without making image checkpointing select an ambiguous extension set."
  (let ((directory (mutation-journal-directory)))
    (loop for path in (or (ignore-errors (directory (merge-pathnames "*.sexp" directory))) nil)
          for journal = (ignore-errors
                          (multiple-value-bind (form complete-p)
                              (sexp-store:snapshot-read path)
                            (and complete-p form)))
          when (and (listp journal) (eq (getf journal :state) :committed)
                    (stringp (getf journal :id)))
            collect (getf journal :id))))

(defun generation-precheck ()
  "Capture the durable mutation frontier before checkpoint publication starts."
  (list :committed-mutations (committed-mutation-ids)))

(defun validate-generation-precheck (precheck)
  "Refuse a checkpoint if a mutation committed while it was being prepared."
  (unless (equal (getf precheck :committed-mutations) (committed-mutation-ids))
    (error "Committed mutations changed while preparing the checkpoint"))
  precheck)

(defun generation-metadata (identifier precheck)
  "Return detached cl-agent state that identifies a saved image generation."
  (list :cl-agent-generation *generation-manifest-version*
        :agent-generation-id identifier
        :committed-mutations (copy-list (getf precheck :committed-mutations))))

(defun allocate-generation-id ()
  "Allocate a timestamped generation ID that cannot collide with an artifact."
  (let ((root (generations-directory)))
    (idsmall:identifier-generate
     :namespace :cl-agent-generation
     :occupied-p (lambda (identifier)
                   (probe-file (merge-pathnames (format nil "~a/" identifier) root))))))

(defun generation-resume-toplevel (arguments)
  "Entry point installed in a saved core after a successful checkpoint."
  (declare (ignore arguments))
  (main))

(defun make-agent-checkpoint-backend ()
  "Build the real SBCL checkpoint backend for the active config directory.

SBCL-GENERATIONS itself checks that the caller is the only live Lisp thread
before it forks.  That refusal is intentional: a checkpoint must never save an
image with threads whose state cannot survive fork-and-save."
  (sbcl-generations:make-checkpoint-backend
   :store (agent-generation-store)
   :toplevel-function #'generation-resume-toplevel
   :identifier-function #'allocate-generation-id
   :precheck-function #'generation-precheck
   :validate-function #'validate-generation-precheck
   :metadata-function #'generation-metadata
   :probe-runner
   (sbcl-generations:make-sbcl-core-probe-runner
    :command (namestring sb-ext:*runtime-pathname*))))

(defun checkpoint-agent-generation ()
  "Begin an asynchronous whole-image checkpoint and return its generation.

The returned generation begins in :PENDING state.  Its status changes to
:READY only after the library has booted and verified the saved core, published
the manifest, and atomically selected it for recovery."
  (sbcl-generations:checkpoint-create (make-agent-checkpoint-backend)))

(defun list-agent-generations ()
  "Return retained compatible generation records, newest first."
  (sbcl-generations:generation-list (agent-generation-store)))

(defun selected-agent-generation ()
  "Return the currently selected recovery generation, if its pointer is valid."
  (sbcl-generations:generation-selected (agent-generation-store)))

(defun request-generation-rollback (identifier)
  "Durably select IDENTIFIER, then signal the library's restart request."
  (sbcl-generations:generation-request-rollback (agent-generation-store) identifier))

(defun generation-summary (generation)
  "Render the inspectable facts about one retained GENERATION."
  (format nil "~a  ~(~a~)  created ~a~@[  mutations: ~{~a~^, ~}~]"
          (sbcl-generations:generation-identifier generation)
          (sbcl-generations:generation-status generation)
          (sbcl-generations:generation-created-at generation)
          (getf (sbcl-generations:generation-metadata generation) :committed-mutations)))
