;;;; mutation/transaction.lisp -- staged extension install and registry rollback.

(in-package :cl-agent)

(defparameter *extension-integration-operators*
  '("DEFINE-TOOL" "ADD-HOOK" "DEFMETHOD" "REGISTER-PROVIDER-CLASS"
    "REGISTER-FRONTEND-CLASS" "DEFINE-SLASH-COMMAND"))

(defun read-extension-top-level-forms (source)
  "Read SOURCE with reader evaluation disabled, rejecting trailing garbage."
  (with-input-from-string (in source)
    (let ((*read-eval* nil) (forms nil))
      (loop for form = (read in nil :eof)
            until (eq form :eof) do (push form forms))
      (nreverse forms))))

(defun extension-form-operator-name (form)
  (and (consp form) (symbolp (car form)) (string-upcase (symbol-name (car form)))))

(defun extension-source-integrates-p (source)
  "Determine integration from parsed top-level forms, never substring matches."
  (some (lambda (form)
          (member (extension-form-operator-name form) *extension-integration-operators*
                  :test #'string=))
        (read-extension-top-level-forms source)))

(defun snapshot-hash-table (table)
  (let ((copy (make-hash-table :test (hash-table-test table)))
        (entries nil))
    (maphash (lambda (key value) (push (cons key value) entries)) table)
    (dolist (entry entries copy) (setf (gethash (car entry) copy) (cdr entry)))))

(defun later-registry-value (name)
  "Read a registry defined later in ASDF load order without creating it early."
  (let ((symbol (find-symbol name :cl-agent)))
    (and symbol (boundp symbol) (symbol-value symbol))))

(defun set-later-registry-value (name value)
  (let ((symbol (find-symbol name :cl-agent)))
    (unless symbol (error "Registry ~a has not been defined" name))
    (setf (symbol-value symbol) value)))

(defun snapshot-mutation-state ()
  (list :tools (snapshot-hash-table *tools*)
        :hooks (snapshot-hash-table *hooks*)
        :providers (snapshot-hash-table *provider-registry*)
        :frontends (snapshot-hash-table (later-registry-value "*FRONTEND-REGISTRY*"))
        :commands (copy-tree (later-registry-value "*SLASH-COMMANDS*"))
        :exercises (snapshot-hash-table *mutation-exercises*)
        :components (snapshot-hash-table *components*)))

(defun restore-mutation-state (snapshot)
  (setf *tools* (getf snapshot :tools)
        *hooks* (getf snapshot :hooks)
        *provider-registry* (getf snapshot :providers)
        *mutation-exercises* (getf snapshot :exercises)
        *components* (getf snapshot :components))
  (set-later-registry-value "*FRONTEND-REGISTRY*" (getf snapshot :frontends))
  (set-later-registry-value "*SLASH-COMMANDS*" (getf snapshot :commands))
  t)

(defun rollback-mutation-live-state (transaction)
  "Restore definitions and registries captured before a live install."
  (rollback-mutation-definitions transaction)
  (when (mutation-before-state transaction)
    (restore-mutation-state (mutation-before-state transaction)))
  transaction)

(defun propose-extension (filename source)
  "Stage an extension proposal without changing an active extension or image."
  (let* ((bare (normalized-extension-filename filename))
         (id (new-mutation-id))
         (stage-directory (merge-pathnames (format nil "~a/" id) (mutations-directory)))
         (staged (merge-pathnames bare stage-directory))
         (target (merge-pathnames bare (extensions-directory)))
         (transaction (make-instance 'mutation-transaction
                                     :id id :owner (format nil "extension:~a" bare)
                                     :filename bare :target target :source source
                                     :staged-source staged)))
    (unless (stringp source) (error "Extension source must be a string"))
    (ensure-mutation-directories)
    (write-string-atomically staged source)
    (setf (gethash id *mutations*) transaction)
    (mutation-receipt transaction :proposed :staged-source (namestring staged))
    (emit-event :mutation-proposed :component (mutation-owner transaction)
                :payload (mutation->plist transaction))
    transaction))

(defun preflight-mutation (transaction)
  "Validate a staged proposal before it can alter the active registry.

This is deliberately a reader/review boundary.  A clean-process load probe is
the next P2 increment; this function does not claim to contain arbitrary Lisp
top-level effects."
  (unless (eq (mutation-state transaction) :proposed)
    (error "Mutation ~a is not proposed (state ~a)" (mutation-id transaction) (mutation-state transaction)))
  (handler-case
      (let ((forms (read-extension-top-level-forms (mutation-source transaction)))
            (review (review-lisp-source (mutation-source transaction))))
        (unless (and forms (extension-source-integrates-p (mutation-source transaction)))
          (error "Source does not contain a supported cl-agent integration form"))
        (when (getf review :compile-failure-p)
          (error "Source did not compile: ~a" (format-lisp-review review)))
        (let ((probe (run-clean-process-probe transaction)))
          (unless (eq (getf probe :status) :passed)
            (error "Clean-process probe failed: ~a"
                   (or (getf probe :detail) (getf probe :error-output) (getf probe :output))))
          (mutation-receipt transaction :clean-probe :probe probe))
        (setf (mutation-state transaction) :preflighted)
        (mutation-receipt transaction :preflighted :forms (length forms) :review review)
        transaction)
    (error (condition)
      (setf (mutation-state transaction) :failed)
      (mutation-receipt transaction :failed :phase :preflight :detail (princ-to-string condition))
      (error condition))))

(defun install-mutation (transaction)
  "Load staged source under transaction ownership; restore registries on error."
  (unless (eq (mutation-state transaction) :preflighted)
    (error "Mutation ~a must be preflighted before installation" (mutation-id transaction)))
  (let ((snapshot (snapshot-mutation-state)))
    (setf (mutation-before-state transaction) snapshot)
    (handler-case
        (progn
          (load-mutation-extension-file transaction)
          (setf (mutation-state transaction) :installed)
          (mutation-receipt transaction :installed :rollback :registry-snapshot)
          (emit-event :mutation-installed :component (mutation-owner transaction)
                      :payload (mutation->plist transaction))
          transaction)
      (error (condition)
        (rollback-mutation-live-state transaction)
        (setf (mutation-state transaction) :failed)
        (mutation-receipt transaction :rolled-back :phase :install
                          :detail (princ-to-string condition) :rollback :registry-snapshot)
        (emit-event :mutation-rolled-back :component (mutation-owner transaction)
                    :payload (mutation->plist transaction))
        (error condition)))))

(defun exercise-mutation (transaction)
  "Run focused checks for an installed mutation before it may be committed.

An exercise failure restores the registry snapshot captured by
INSTALL-MUTATION.  Like registry discard generally, this cannot undo arbitrary
top-level side effects; the clean-process preflight remains the first safety
boundary."
  (unless (eq (mutation-state transaction) :installed)
    (error "Mutation ~a must be installed before exercises run" (mutation-id transaction)))
  (handler-case
      (progn
        (run-mutation-exercises transaction)
        (setf (mutation-state transaction) :exercised)
        (mutation-receipt transaction :exercised)
        (emit-event :mutation-exercised :component (mutation-owner transaction)
                    :payload (mutation->plist transaction))
        transaction)
    (error (condition)
      (rollback-mutation-live-state transaction)
      (setf (mutation-state transaction) :failed)
      (mutation-receipt transaction :rolled-back :phase :exercise
                        :detail (princ-to-string condition) :rollback :registry-snapshot)
      (emit-event :mutation-rolled-back :component (mutation-owner transaction)
                  :payload (mutation->plist transaction))
      (error condition))))

(defun discard-mutation (transaction)
  "Restore the registry state captured before installation, if still available."
  (unless (member (mutation-state transaction) '(:installed :exercised :failed))
    (error "Only installed, exercised, or failed mutations can be discarded"))
  (rollback-mutation-live-state transaction)
  (setf (mutation-state transaction) :discarded)
  (mutation-receipt transaction :discarded :rollback :registry-snapshot)
  (emit-event :mutation-discarded :component (mutation-owner transaction)
              :payload (mutation->plist transaction))
  transaction)
