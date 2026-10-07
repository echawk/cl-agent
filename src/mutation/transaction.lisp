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

(defun snapshot-mutation-state ()
  (list :tools (snapshot-hash-table *tools*)
        :hooks (snapshot-hash-table *hooks*)
        :providers (snapshot-hash-table *provider-registry*)
        :frontends (snapshot-hash-table *frontend-registry*)
        :commands (copy-tree *slash-commands*)
        :components (snapshot-hash-table *components*)))

(defun restore-mutation-state (snapshot)
  (setf *tools* (getf snapshot :tools)
        *hooks* (getf snapshot :hooks)
        *provider-registry* (getf snapshot :providers)
        *frontend-registry* (getf snapshot :frontends)
        *slash-commands* (getf snapshot :commands)
        *components* (getf snapshot :components))
  t)

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
          (load-extension-file (mutation-staged-source transaction)
                               :owner (mutation-owner transaction)
                               :origin (list :mutation (mutation-id transaction)))
          (setf (mutation-state transaction) :installed)
          (mutation-receipt transaction :installed :rollback :registry-snapshot)
          (emit-event :mutation-installed :component (mutation-owner transaction)
                      :payload (mutation->plist transaction))
          transaction)
      (error (condition)
        (restore-mutation-state snapshot)
        (setf (mutation-state transaction) :failed)
        (mutation-receipt transaction :rolled-back :phase :install
                          :detail (princ-to-string condition) :rollback :registry-snapshot)
        (emit-event :mutation-rolled-back :component (mutation-owner transaction)
                    :payload (mutation->plist transaction))
        (error condition)))))

(defun discard-mutation (transaction)
  "Restore the registry state captured before installation, if still available."
  (unless (member (mutation-state transaction) '(:installed :failed))
    (error "Only installed or failed mutations can be discarded"))
  (when (mutation-before-state transaction)
    (restore-mutation-state (mutation-before-state transaction)))
  (setf (mutation-state transaction) :discarded)
  (mutation-receipt transaction :discarded :rollback :registry-snapshot)
  (emit-event :mutation-discarded :component (mutation-owner transaction)
              :payload (mutation->plist transaction))
  transaction)
