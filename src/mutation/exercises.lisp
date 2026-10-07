;;;; mutation/exercises.lisp -- focused, owned verification for staged changes.

(in-package :cl-agent)

(defclass mutation-exercise ()
  ((id :initarg :id :reader mutation-exercise-id)
   (description :initarg :description :initform "" :reader mutation-exercise-description)
   (owner :initarg :owner :reader mutation-exercise-owner)
   (runner :initarg :runner :reader mutation-exercise-runner))
  (:documentation "A named, transaction-owned smoke check.

The runner receives no arguments and must return normally to pass.  It may
signal a condition to fail its mutation.  Exercises deliberately run after
the staged source has loaded into the live image, so they can invoke a newly
registered tool or inspect a newly installed hook/provider."))

(defvar *mutation-exercises* (make-hash-table :test #'equal)
  "Qualified exercise ID -> MUTATION-EXERCISE.")

(defun mutation-exercise-key (owner id)
  (format nil "~a/~a" owner (string-downcase (string id))))

(defun register-mutation-exercise (exercise)
  "Register EXERCISE under its owner, replacing an earlier exercise of that name."
  (setf (gethash (mutation-exercise-key (mutation-exercise-owner exercise)
                                         (mutation-exercise-id exercise))
                 *mutation-exercises*)
        exercise)
  exercise)

(defmacro define-mutation-exercise (name (&key description) &body body)
  "Define a focused verification check owned by the loading mutation.

Use this in an extension after its registrations.  BODY should signal an
error when its assertion fails.  For example:

  (define-mutation-exercise my-tool-smoke ()
    (unless (search \"ready\" (call-tool \"my-tool\" (jobj)))
      (error \"my-tool did not return its expected result\")))"
  `(register-mutation-exercise
    (make-instance 'mutation-exercise
                   :id ',name
                   :description ,description
                   :owner (or *registration-owner* "runtime")
                   :runner (lambda () ,@body))))

(defun mutation-exercises-owned-by (owner)
  (sort (loop for exercise being the hash-values of *mutation-exercises*
              when (equal owner (mutation-exercise-owner exercise))
              collect exercise)
        #'string< :key (lambda (exercise) (string-downcase (string (mutation-exercise-id exercise))))))

(defun mutation-component-exercise-evidence (transaction)
  "Return data-only evidence of components now owned by TRANSACTION.

This baseline observation makes every exercise receipt useful even for an
extension which declares no custom smoke test.  It intentionally does not
require a component: a DEFMETHOD-only extension is a supported integration."
  (mapcar #'component->plist
          (list-components :owner (mutation-owner transaction))))

(defun run-mutation-exercises (transaction)
  "Run TRANSACTION's owned checks and append a receipt for each result.

Signals on the first failed exercise.  The caller owns rollback, allowing the
same failure path to restore all behavioral registries before any source is
published."
  (let ((exercises (mutation-exercises-owned-by (mutation-owner transaction))))
    (mutation-receipt transaction :exercise
                       :exercise-id :component-inventory
                       :status :passed
                       :components (mutation-component-exercise-evidence transaction))
    (dolist (exercise exercises)
      (handler-case
          (progn
            (funcall (mutation-exercise-runner exercise))
            (mutation-receipt transaction :exercise
                               :exercise-id (mutation-exercise-id exercise)
                               :description (mutation-exercise-description exercise)
                               :status :passed))
        (error (condition)
          (mutation-receipt transaction :exercise
                             :exercise-id (mutation-exercise-id exercise)
                             :description (mutation-exercise-description exercise)
                             :status :failed
                             :detail (princ-to-string condition))
          (error "Mutation exercise ~a failed: ~a"
                 (mutation-exercise-id exercise) condition))))
    exercises))
