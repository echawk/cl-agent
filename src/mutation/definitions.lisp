;;;; mutation/definitions.lisp -- Surgeon-backed reversible live definitions.

(in-package :cl-agent)

(defstruct mutation-definition-undo
  "A live undo closure and its data-only journal identity."
  key operator undo)

(defun mutation-previous-definition-source (transaction definition)
  "Find DEFINITION's previous source in TRANSACTION's active target, if any.

Surgeon needs this exact text to reverse an existing class-like definition.
Absence is normal for a newly introduced definition; unsupported or missing
source is left for Surgeon to reject rather than guessed from the image."
  (let ((target (probe-file (mutation-target transaction))))
    (when target
      (handler-case
          (multiple-value-bind (source-form source)
              (surgeon:source-find-definition target definition
                                              :package (find-package :cl-agent))
            (subseq source (surgeon:source-form-start source-form)
                    (surgeon:source-form-end source-form)))
        (surgeon:definition-not-found () nil)))))

(defun capture-mutation-definition-undo (transaction definition)
  "Capture Surgeon undo state before evaluating one supported DEFINITION."
  (let* ((operator (first definition))
         (key (surgeon:definition-key definition))
         (undo (surgeon:definition-undo-capture
                operator definition *package*
                :previous-source (mutation-previous-definition-source transaction definition))))
    (push (make-mutation-definition-undo :key key :operator operator :undo undo)
          (mutation-definition-undo-actions transaction))
    (push (list :key key :operator operator :status :captured)
          (mutation-definition-changes transaction))
    undo))

(defun rollback-mutation-definitions (transaction)
  "Run captured definition undo actions in reverse installation order.

Returns true when every action restored successfully.  Callers continue to
restore registry state even if an undo reports a failure, so a failed mutation
does not retain registrations merely because one definition was problematic."
  (let ((ok t))
    ;; Actions are PUSHed before each evaluation, so this order is already
    ;; newest-to-oldest and is the required reverse installation order.
    (dolist (action (mutation-definition-undo-actions transaction))
      (handler-case
          (progn
            (funcall (mutation-definition-undo-undo action))
            (push (list :key (mutation-definition-undo-key action)
                        :operator (mutation-definition-undo-operator action)
                        :status :restored)
                  (mutation-definition-changes transaction)))
        (error (condition)
          (setf ok nil)
          (push (list :key (mutation-definition-undo-key action)
                      :operator (mutation-definition-undo-operator action)
                      :status :restore-failed :detail (princ-to-string condition))
                (mutation-definition-changes transaction)))))
    (setf (mutation-definition-undo-actions transaction) nil)
    ok))

(defun load-mutation-extension-file (transaction)
  "Evaluate TRANSACTION's staged source while capturing reversible definitions.

Only the mutation installation path uses this loader.  Ordinary extension
startup keeps LOAD's established behavior; transaction installation evaluates
top-level forms one at a time so Surgeon can snapshot each definition before
it changes the live image."
  (let ((path (mutation-staged-source transaction)))
    (run-hook :before-extension-load path)
    (handler-case
        (let ((*registration-origin* (list :mutation (mutation-id transaction)))
              (*registration-owner* (mutation-owner transaction))
              (*package* (find-package :cl-agent)))
          (dolist (source-form (surgeon:source-read-forms
                                (uiop:read-file-string path) :package *package*))
            (let ((form (surgeon:source-form-form source-form)))
              (when (surgeon:definition-form-p form)
                (capture-mutation-definition-undo transaction form))
              (eval form)))
          (run-hook :after-extension-load path)
          t)
      (error (condition)
        (error 'extension-error :path path :original-condition condition)))))
